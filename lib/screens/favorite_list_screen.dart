import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';

import '../main.dart'
    show kSurface, kBackground, kTextDark, kTextMuted, kBorderColor;
import '../services/favorite_service.dart';
import 'login_screen.dart';

/// 관심 매물(찜) 목록 화면.
///
/// Firestore `users/{uid}/favorites` 컬렉션을 실시간 구독하여
/// 사용자가 찜한 아파트 단지 목록을 표시합니다.
class FavoriteListScreen extends StatelessWidget {
  const FavoriteListScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<User?>(
      stream: FirebaseAuth.instance.authStateChanges(),
      builder: (context, authSnap) {
        final user = authSnap.data;
        if (user == null) {
          return _buildLoginRequired(context);
        }
        return _FavoriteListBody(uid: user.uid);
      },
    );
  }

  Widget _buildLoginRequired(BuildContext context) {
    return Scaffold(
      backgroundColor: kBackground,
      appBar: AppBar(title: const Text('관심 매물')),
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              width: 80,
              height: 80,
              decoration: BoxDecoration(
                color: const Color(0xFFE53935).withValues(alpha: 0.08),
                shape: BoxShape.circle,
              ),
              child: const Icon(Icons.favorite_outline_rounded,
                  size: 40, color: Color(0xFFE53935)),
            ),
            const SizedBox(height: 20),
            const Text(
              '로그인이 필요합니다',
              style: TextStyle(
                fontSize: 17,
                fontWeight: FontWeight.w700,
                color: kTextDark,
                letterSpacing: -0.3,
              ),
            ),
            const SizedBox(height: 8),
            const Text(
              '관심 매물을 저장하고 한눈에 확인하려면\n로그인해 주세요.',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 13.5, color: kTextMuted, height: 1.6),
            ),
            const SizedBox(height: 28),
            ElevatedButton(
              onPressed: () => Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const LoginScreen()),
              ),
              style: ElevatedButton.styleFrom(
                minimumSize: const Size(180, 48),
              ),
              child: const Text('로그인하기'),
            ),
          ],
        ),
      ),
    );
  }
}

class _FavoriteListBody extends StatelessWidget {
  const _FavoriteListBody({required this.uid});

  final String uid;

  @override
  Widget build(BuildContext context) {
    final service = FavoriteService();

    return Scaffold(
      backgroundColor: kBackground,
      appBar: AppBar(
        title: const Text('관심 매물'),
      ),
      body: StreamBuilder<List<FavoriteItem>>(
        stream: service.favoritesStream(),
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

          final items = snap.data ?? [];
          if (items.isEmpty) {
            return _buildEmptyState();
          }

          return ListView.separated(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 40),
            itemCount: items.length,
            separatorBuilder: (ctx, i) => const SizedBox(height: 10),
            itemBuilder: (context, index) =>
                _FavoriteCard(item: items[index], service: service),
          );
        },
      ),
    );
  }

  Widget _buildEmptyState() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(
            width: 80,
            height: 80,
            decoration: BoxDecoration(
              color: const Color(0xFFE53935).withValues(alpha: 0.07),
              shape: BoxShape.circle,
            ),
            child: const Icon(Icons.favorite_outline_rounded,
                size: 40, color: Color(0xFFE53935)),
          ),
          const SizedBox(height: 20),
          const Text(
            '아직 관심 매물이 없어요',
            style: TextStyle(
              fontSize: 17,
              fontWeight: FontWeight.w700,
              color: kTextDark,
              letterSpacing: -0.3,
            ),
          ),
          const SizedBox(height: 8),
          const Text(
            '지도에서 아파트를 찾아\n하트 버튼을 눌러 저장해 보세요.',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 13.5, color: kTextMuted, height: 1.6),
          ),
        ],
      ),
    );
  }
}

class _FavoriteCard extends StatelessWidget {
  const _FavoriteCard({required this.item, required this.service});

  final FavoriteItem item;
  final FavoriteService service;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: kSurface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: kBorderColor),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.03),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            // 아이콘 박스
            Container(
              width: 52,
              height: 52,
              decoration: BoxDecoration(
                color: const Color(0xFFE53935).withValues(alpha: 0.08),
                borderRadius: BorderRadius.circular(14),
              ),
              child: const Icon(
                Icons.apartment_rounded,
                color: Color(0xFFE53935),
                size: 26,
              ),
            ),
            const SizedBox(width: 14),
            // 단지 정보
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    item.kaptName,
                    style: const TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w700,
                      color: kTextDark,
                      letterSpacing: -0.3,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  if (item.kaptAddr.isNotEmpty) ...[
                    const SizedBox(height: 4),
                    Row(
                      children: [
                        Icon(Icons.location_on_outlined,
                            size: 12, color: Colors.grey.shade400),
                        const SizedBox(width: 3),
                        Expanded(
                          child: Text(
                            item.kaptAddr,
                            style: TextStyle(
                              fontSize: 12,
                              color: Colors.grey.shade500,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ),
                  ],
                  if (item.savedAt != null) ...[
                    const SizedBox(height: 4),
                    Text(
                      '저장일 ${_formatDate(item.savedAt!)}',
                      style: TextStyle(
                        fontSize: 11,
                        color: Colors.grey.shade400,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            // 삭제 버튼
            IconButton(
              icon: const Icon(Icons.favorite_rounded,
                  color: Color(0xFFE53935), size: 22),
              tooltip: '관심 매물 해제',
              onPressed: () => _confirmRemove(context),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _confirmRemove(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('관심 매물 해제'),
        content: Text(
          '${item.kaptName}을(를) 관심 매물에서 삭제할까요?',
          style: const TextStyle(fontSize: 14, height: 1.5),
        ),
        actionsPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        actions: [
          OutlinedButton(
            onPressed: () => Navigator.pop(ctx, false),
            style: OutlinedButton.styleFrom(minimumSize: const Size(72, 44)),
            child: const Text('취소'),
          ),
          const SizedBox(width: 8),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFFE53935),
              minimumSize: const Size(88, 44),
            ),
            child: const Text('삭제'),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      await service.removeFavorite(item.id);
    }
  }

  String _formatDate(DateTime dt) =>
      '${dt.year}.${dt.month.toString().padLeft(2, '0')}.${dt.day.toString().padLeft(2, '0')}';
}
