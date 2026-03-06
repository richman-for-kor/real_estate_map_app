import 'package:cached_network_image/cached_network_image.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import '../main.dart'
    show kPrimary, kSurface, kBackground, kTextDark, kTextMuted;
import 'write_imjang_screen.dart';

/// 임장 노트 탭 화면.
///
/// Firestore `imjang_records` 컬렉션에서 로그인한 사용자 본인의 기록을 실시간으로
/// 구독하여 카드 목록으로 표시합니다. 지역 필터는 클라이언트 사이드에서 처리합니다.
class ImjangScreen extends StatefulWidget {
  const ImjangScreen({super.key});

  @override
  State<ImjangScreen> createState() => _ImjangScreenState();
}

class _ImjangScreenState extends State<ImjangScreen> {
  int _selectedFilter = 0;

  static const _kFilters = ['전체', '서울', '경기/인천', '지방', '부산/경남'];

  // ── Build ────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: kBackground,
      appBar: AppBar(
        title: const Text('내 임장노트'),
        actions: [
          IconButton(
            icon: const Icon(Icons.search_rounded),
            tooltip: '노트 검색',
            onPressed: () {},
          ),
        ],
      ),
      body: StreamBuilder<User?>(
        stream: FirebaseAuth.instance.authStateChanges(),
        builder: (context, authSnap) {
          final user = authSnap.data;
          if (user == null) {
            return _buildLoginPrompt();
          }
          return Column(
            children: [
              _buildFilterChips(),
              Expanded(child: _buildRecordsList(user.uid)),
            ],
          );
        },
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _openWriteScreen,
        icon: const Icon(Icons.edit_rounded, size: 20),
        label: const Text(
          '노트 작성',
          style: TextStyle(fontWeight: FontWeight.w700, fontSize: 14),
        ),
        backgroundColor: kPrimary,
        foregroundColor: Colors.white,
        elevation: 4,
      ),
    );
  }

  // ── Navigation ───────────────────────────────────────────────────────────

  Future<void> _openWriteScreen() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('임장 노트를 작성하려면 로그인이 필요합니다.'),
          margin: EdgeInsets.all(16),
        ),
      );
      return;
    }
    await Navigator.push<bool>(
      context,
      MaterialPageRoute(builder: (_) => const WriteImjangScreen()),
    );
  }

  // ── 필터 칩 ──────────────────────────────────────────────────────────────

  Widget _buildFilterChips() {
    return Container(
      color: kSurface,
      height: 54,
      child: ListView.builder(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
        itemCount: _kFilters.length,
        itemBuilder: (context, index) {
          final isSelected = _selectedFilter == index;
          return Padding(
            padding: const EdgeInsets.only(right: 8),
            child: GestureDetector(
              onTap: () => setState(() => _selectedFilter = index),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 180),
                curve: Curves.easeOut,
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 7),
                decoration: BoxDecoration(
                  color: isSelected ? kTextDark : Colors.grey.shade100,
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Text(
                  _kFilters[index],
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight:
                        isSelected ? FontWeight.w700 : FontWeight.w500,
                    color:
                        isSelected ? Colors.white : Colors.grey.shade600,
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  // ── 노트 목록 (Firestore StreamBuilder) ──────────────────────────────────

  Widget _buildRecordsList(String uid) {
    final query = FirebaseFirestore.instance
        .collection('imjang_records')
        .where('uid', isEqualTo: uid)
        .orderBy('createdAt', descending: true);

    return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
      stream: query.snapshots(),
      builder: (context, snap) {
        if (snap.hasError) {
          return Center(
            child: Text(
              '불러오기 실패: ${snap.error}',
              style: const TextStyle(color: Colors.grey),
            ),
          );
        }
        if (snap.connectionState == ConnectionState.waiting) {
          return const Center(child: CircularProgressIndicator());
        }

        // 클라이언트 사이드 지역 필터 적용
        var docs = snap.data!.docs;
        if (_selectedFilter != 0) {
          final filterRegion = _kFilters[_selectedFilter];
          docs = docs
              .where((d) => (d.data()['region'] as String?) == filterRegion)
              .toList();
        }

        if (docs.isEmpty) {
          return _buildEmptyState();
        }

        return ListView.builder(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 100),
          itemCount: docs.length,
          itemBuilder: (context, index) =>
              _buildNoteCard(docs[index].data()),
        );
      },
    );
  }

  // ── 노트 카드 ─────────────────────────────────────────────────────────────

  Widget _buildNoteCard(Map<String, dynamic> data) {
    final title = data['title'] as String? ?? '(제목 없음)';
    final address = data['address'] as String? ?? '';
    final review = data['review'] as String? ?? '';
    final mediaUrls = (data['mediaUrls'] as List<dynamic>?)
            ?.whereType<String>()
            .toList() ??
        [];
    final createdAt = data['createdAt'] as Timestamp?;
    final dateStr = createdAt != null ? _formatDate(createdAt.toDate()) : '';

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        color: kSurface,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.03),
            blurRadius: 10,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: InkWell(
        onTap: () {},
        borderRadius: BorderRadius.circular(16),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 사진 썸네일
            Container(
              width: 88,
              height: 88,
              margin: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.grey.shade100,
                borderRadius: BorderRadius.circular(12),
              ),
              child: mediaUrls.isNotEmpty
                  ? ClipRRect(
                      borderRadius: BorderRadius.circular(12),
                      child: CachedNetworkImage(
                        imageUrl: mediaUrls.first,
                        fit: BoxFit.cover,
                        placeholder: (ctx, url) => const Center(
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                        errorWidget: (ctx, url, err) =>
                            _photoPlaceholder(hasError: true),
                      ),
                    )
                  : _photoPlaceholder(hasError: false),
            ),
            // 콘텐츠
            Expanded(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(4, 14, 14, 14),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // 주소 태그
                    if (address.isNotEmpty)
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 7, vertical: 3),
                        decoration: BoxDecoration(
                          color: kPrimary.withValues(alpha: 0.08),
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.location_on_rounded,
                                size: 10, color: kPrimary),
                            const SizedBox(width: 3),
                            Flexible(
                              child: Text(
                                address,
                                style: const TextStyle(
                                  fontSize: 10,
                                  fontWeight: FontWeight.w600,
                                  color: kPrimary,
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          ],
                        ),
                      ),
                    const SizedBox(height: 7),
                    // 제목
                    Text(
                      title,
                      style: const TextStyle(
                        fontSize: 14.5,
                        fontWeight: FontWeight.w700,
                        color: kTextDark,
                        letterSpacing: -0.3,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 5),
                    // 미리보기 텍스트
                    Text(
                      review,
                      style: const TextStyle(
                        fontSize: 12,
                        color: kTextMuted,
                        height: 1.45,
                      ),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 9),
                    // 날짜 + 사진 수
                    Row(
                      children: [
                        Icon(Icons.calendar_today_outlined,
                            size: 11, color: Colors.grey.shade400),
                        const SizedBox(width: 4),
                        Text(
                          dateStr,
                          style: TextStyle(
                            fontSize: 11,
                            color: Colors.grey.shade400,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                        if (mediaUrls.isNotEmpty) ...[
                          const SizedBox(width: 8),
                          Icon(Icons.photo_outlined,
                              size: 11, color: Colors.grey.shade400),
                          const SizedBox(width: 3),
                          Text(
                            '${mediaUrls.length}',
                            style: TextStyle(
                              fontSize: 11,
                              color: Colors.grey.shade400,
                            ),
                          ),
                        ],
                        const Spacer(),
                        Icon(Icons.chevron_right_rounded,
                            size: 18, color: Colors.grey.shade300),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _photoPlaceholder({required bool hasError}) {
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Icon(
          hasError ? Icons.broken_image_outlined : Icons.photo_camera_outlined,
          color: Colors.grey.shade400,
          size: 24,
        ),
        const SizedBox(height: 2),
        Text(
          '사진 없음',
          style: TextStyle(
            color: Colors.grey.shade400,
            fontSize: 9,
            fontWeight: FontWeight.w500,
          ),
        ),
      ],
    );
  }

  // ── 빈 상태 ───────────────────────────────────────────────────────────────

  Widget _buildEmptyState() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(
            width: 80,
            height: 80,
            decoration: BoxDecoration(
              color: kPrimary.withValues(alpha: 0.07),
              shape: BoxShape.circle,
            ),
            child: const Icon(Icons.edit_note_rounded,
                size: 40, color: kPrimary),
          ),
          const SizedBox(height: 20),
          const Text(
            '아직 임장 노트가 없어요',
            style: TextStyle(
              fontSize: 17,
              fontWeight: FontWeight.w700,
              color: kTextDark,
              letterSpacing: -0.3,
            ),
          ),
          const SizedBox(height: 8),
          const Text(
            '직접 방문한 매물의 현장 감상을\n노트로 기록해 보세요.',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 13.5,
              color: kTextMuted,
              height: 1.6,
            ),
          ),
          const SizedBox(height: 32),
          ElevatedButton.icon(
            onPressed: _openWriteScreen,
            icon: const Icon(Icons.edit_rounded, size: 18),
            label: const Text('첫 번째 노트 작성하기'),
            style: ElevatedButton.styleFrom(
              minimumSize: const Size(200, 48),
            ),
          ),
        ],
      ),
    );
  }

  // ── 비로그인 안내 ─────────────────────────────────────────────────────────

  Widget _buildLoginPrompt() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(
            width: 80,
            height: 80,
            decoration: BoxDecoration(
              color: Colors.grey.shade100,
              shape: BoxShape.circle,
            ),
            child: Icon(Icons.lock_outline_rounded,
                size: 36, color: Colors.grey.shade400),
          ),
          const SizedBox(height: 20),
          Text(
            '로그인이 필요합니다',
            style: TextStyle(
              fontSize: 17,
              fontWeight: FontWeight.w700,
              color: kTextDark,
              letterSpacing: -0.3,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            '임장 노트를 작성하고 확인하려면\n로그인해 주세요.',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 13.5,
              color: kTextMuted,
              height: 1.6,
            ),
          ),
        ],
      ),
    );
  }

  // ── 유틸 ─────────────────────────────────────────────────────────────────

  String _formatDate(DateTime dt) {
    return '${dt.year}.${dt.month.toString().padLeft(2, '0')}.${dt.day.toString().padLeft(2, '0')}';
  }
}
