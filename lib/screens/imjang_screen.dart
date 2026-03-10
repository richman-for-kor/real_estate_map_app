import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import '../main.dart'
    show kPrimary, kPrimaryLight, kSurface, kBackground, kTextDark, kTextMuted, kBorderColor;
import 'imjang_note_detail_screen.dart';
import 'write_imjang_screen.dart';

/// 임장 노트 탭 화면.
///
/// - 상단 검색바: 아파트 단지명(title) 클라이언트 사이드 검색
/// - 필터 바: 시도/시군구/읍면동 드롭다운(좌) + 연도 드롭다운(우)
/// - 페이지네이션: 10건씩 로드, 스크롤 하단 도달 시 추가 로드
class ImjangScreen extends StatefulWidget {
  const ImjangScreen({super.key});

  @override
  State<ImjangScreen> createState() => _ImjangScreenState();
}

class _ImjangScreenState extends State<ImjangScreen> {
  // ── 시도 목록 (정적) ───────────────────────────────────────────────────────
  static const _kSidoList = [
    '서울', '경기', '인천', '부산', '대구', '광주', '대전',
    '울산', '세종', '강원', '충북', '충남', '전북', '전남',
    '경북', '경남', '제주',
  ];

  // 연도 목록: 현재 연도(2026)부터 2020년까지
  static final _kYearList = List.generate(
    DateTime.now().year - 2019,
    (i) => DateTime.now().year - i,
  );

  // ── 필터 상태 ──────────────────────────────────────────────────────────────
  String? _sido;
  String? _sigungu;
  String? _dong;
  int?    _year;

  // ── 검색 ──────────────────────────────────────────────────────────────────
  final _searchCtrl = TextEditingController();
  String _searchQuery = '';
  Timer? _searchDebounce;

  // ── 페이지네이션 ───────────────────────────────────────────────────────────
  static const _kPageSize = 10;
  final _scrollCtrl = ScrollController();
  List<QueryDocumentSnapshot<Map<String, dynamic>>> _docs = [];
  DocumentSnapshot<Map<String, dynamic>>? _lastDoc;
  bool _isLoading = false;
  bool _hasMore = true;
  String? _loadedForUid;
  // 필터 변경 시 증가 → 이전 비동기 로드 결과를 무시하기 위한 카운터
  int _loadId = 0;

  // ── 중분류/소분류 옵션 ─────────────────────────────────────────────────────
  List<QueryDocumentSnapshot<Map<String, dynamic>>> _allDocsForOptions = [];
  bool _optionsLoading = false;

  @override
  void initState() {
    super.initState();
    _scrollCtrl.addListener(_onScroll);
  }

  @override
  void dispose() {
    _scrollCtrl.dispose();
    _searchCtrl.dispose();
    _searchDebounce?.cancel();
    super.dispose();
  }

  void _onScroll() {
    if (_scrollCtrl.position.pixels >=
        _scrollCtrl.position.maxScrollExtent - 250) {
      if (_loadedForUid != null) _loadMore(_loadedForUid!);
    }
  }

  // ── Firestore 쿼리 빌더 ───────────────────────────────────────────────────

  Query<Map<String, dynamic>> _buildQuery(String uid) {
    // equality where 절을 먼저, orderBy/range를 마지막에 배치
    // → Firestore 복합 인덱스 [uid, sido?, sigungu?, eupmyeondong?, createdAt] 활용
    var q = FirebaseFirestore.instance
        .collection('imjang_records')
        .where('uid', isEqualTo: uid);
    if (_sido != null) q = q.where('sido', isEqualTo: _sido);
    if (_sigungu != null) q = q.where('sigungu', isEqualTo: _sigungu);
    if (_dong != null) q = q.where('eupmyeondong', isEqualTo: _dong);
    if (_year != null) {
      q = q
          .where('createdAt',
              isGreaterThanOrEqualTo: Timestamp.fromDate(DateTime(_year!)))
          .where('createdAt',
              isLessThan: Timestamp.fromDate(DateTime(_year! + 1)));
    }
    return q.orderBy('createdAt', descending: true);
  }

  // ── 데이터 로드 ────────────────────────────────────────────────────────────

  Future<void> _reset(String uid) async {
    setState(() {
      _loadId++;
      _isLoading = false;
      _docs = [];
      _lastDoc = null;
      _hasMore = true;
      _allDocsForOptions = [];
      _optionsLoading = false;
    });
    await _loadMore(uid);
    if (_sido != null) _loadOptionsForSido(uid);
  }

  Future<void> _loadMore(String uid) async {
    if (_isLoading || !_hasMore) return;
    final myLoadId = _loadId;
    setState(() => _isLoading = true);
    try {
      var q = _buildQuery(uid).limit(_kPageSize);
      if (_lastDoc != null) q = q.startAfterDocument(_lastDoc!);
      final snap = await q.get();
      // 로드 중 필터가 바뀌었으면 결과 버림
      if (!mounted || _loadId != myLoadId) return;
      setState(() {
        _docs.addAll(snap.docs);
        if (snap.docs.isNotEmpty) _lastDoc = snap.docs.last;
        _hasMore = snap.docs.length == _kPageSize;
        _isLoading = false;
      });
    } catch (e) {
      if (mounted && _loadId == myLoadId) {
        setState(() => _isLoading = false);
      }
    }
  }

  /// sido 선택 시 해당 지역 전체 문서를 한 번에 조회 → 중분류/소분류 옵션 추출
  Future<void> _loadOptionsForSido(String uid) async {
    setState(() => _optionsLoading = true);
    try {
      final snap = await FirebaseFirestore.instance
          .collection('imjang_records')
          .where('uid', isEqualTo: uid)
          .where('sido', isEqualTo: _sido)
          .get();
      if (mounted) {
        setState(() {
          _allDocsForOptions = snap.docs;
          _optionsLoading = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _optionsLoading = false);
    }
  }

  // ── 동적 옵션 추출 ─────────────────────────────────────────────────────────

  List<String> get _sigunguOptions {
    final set = <String>{};
    for (final d in _allDocsForOptions) {
      final v = d.data()['sigungu'] as String?;
      if (v != null && v.isNotEmpty) set.add(v);
    }
    return set.toList()..sort();
  }

  List<String> get _dongOptions {
    final set = <String>{};
    for (final d in _allDocsForOptions) {
      if (_sigungu != null && d.data()['sigungu'] != _sigungu) continue;
      final v = d.data()['eupmyeondong'] as String?;
      if (v != null && v.isNotEmpty) set.add(v);
    }
    return set.toList()..sort();
  }

  // ── 클라이언트 사이드 검색 필터 ────────────────────────────────────────────

  List<QueryDocumentSnapshot<Map<String, dynamic>>> get _filteredDocs {
    if (_searchQuery.isEmpty) return _docs;
    final q = _searchQuery.toLowerCase();
    return _docs.where((d) {
      final title = (d.data()['title'] as String? ?? '').toLowerCase();
      return title.contains(q);
    }).toList();
  }

  // ── 필터 핸들러 ────────────────────────────────────────────────────────────

  void _onSidoChanged(String? sido, String uid) {
    setState(() {
      _loadId++;
      _isLoading = false;
      _sido = sido;
      _sigungu = null;
      _dong = null;
      _docs = [];
      _lastDoc = null;
      _hasMore = true;
      _allDocsForOptions = [];
    });
    _loadMore(uid);
    if (sido != null) _loadOptionsForSido(uid);
  }

  void _onSigunguChanged(String? sigungu, String uid) {
    setState(() {
      _loadId++;
      _isLoading = false;
      _sigungu = sigungu;
      _dong = null;
      _docs = [];
      _lastDoc = null;
      _hasMore = true;
    });
    _loadMore(uid);
  }

  void _onDongChanged(String? dong, String uid) {
    setState(() {
      _loadId++;
      _isLoading = false;
      _dong = dong;
      _docs = [];
      _lastDoc = null;
      _hasMore = true;
    });
    _loadMore(uid);
  }

  void _onYearChanged(int? year, String uid) {
    setState(() {
      _loadId++;
      _isLoading = false;
      _year = year;
      _docs = [];
      _lastDoc = null;
      _hasMore = true;
    });
    _loadMore(uid);
  }

  // ── 작성 화면 이동 ─────────────────────────────────────────────────────────

  Future<void> _openWriteScreen() async {
    if (FirebaseAuth.instance.currentUser == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('임장 노트를 작성하려면 로그인이 필요합니다.'),
          margin: EdgeInsets.all(16),
        ),
      );
      return;
    }
    final saved = await Navigator.push<bool>(
      context,
      MaterialPageRoute(builder: (_) => const WriteImjangScreen()),
    );
    if (saved == true && _loadedForUid != null) _reset(_loadedForUid!);
  }

  // ── Build ──────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: kBackground,
      appBar: AppBar(
        title: const Text('내 임장노트'),
        backgroundColor: kSurface,
        elevation: 0,
        scrolledUnderElevation: 0,
      ),
      body: StreamBuilder<User?>(
        stream: FirebaseAuth.instance.authStateChanges(),
        builder: (context, authSnap) {
          final user = authSnap.data;
          if (user == null) return _buildLoginPrompt();

          if (_loadedForUid != user.uid && !_isLoading) {
            _loadedForUid = user.uid;
            WidgetsBinding.instance.addPostFrameCallback(
              (_) => _loadMore(user.uid),
            );
          }

          return Column(
            children: [
              _buildSearchBar(),
              _buildFilterBar(user.uid),
              Expanded(
                child: RefreshIndicator(
                  onRefresh: () => _reset(user.uid),
                  color: kPrimary,
                  child: _buildList(),
                ),
              ),
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
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
      ),
    );
  }

  // ── 검색바 ─────────────────────────────────────────────────────────────────

  Widget _buildSearchBar() {
    return Container(
      color: kSurface,
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 10),
      child: Container(
        decoration: BoxDecoration(
          color: kBackground,
          borderRadius: BorderRadius.circular(24),
          boxShadow: const [
            BoxShadow(color: Color(0x0F000000), blurRadius: 16, offset: Offset(0, 4)),
          ],
        ),
        child: TextField(
          controller: _searchCtrl,
          onChanged: (v) {
            _searchDebounce?.cancel();
            _searchDebounce = Timer(const Duration(milliseconds: 300), () {
              if (mounted) setState(() => _searchQuery = v.trim());
            });
          },
          decoration: InputDecoration(
            hintText: '아파트 단지명으로 검색',
            prefixIcon: const Icon(Icons.search_rounded, size: 20, color: kTextMuted),
            suffixIcon: _searchQuery.isNotEmpty
                ? IconButton(
                    icon: const Icon(Icons.close_rounded, size: 18, color: kTextMuted),
                    onPressed: () {
                      _searchCtrl.clear();
                      setState(() => _searchQuery = '');
                    },
                  )
                : null,
            filled: true,
            fillColor: kBackground,
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(24),
              borderSide: BorderSide.none,
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(24),
              borderSide: BorderSide.none,
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(24),
              borderSide: BorderSide(color: kPrimary.withValues(alpha: 0.4)),
            ),
            contentPadding: const EdgeInsets.symmetric(vertical: 10),
            isDense: true,
          ),
        ),
      ),
    );
  }

  // ── 필터 바 (드롭다운) ─────────────────────────────────────────────────────

  Widget _buildFilterBar(String uid) {
    final sigunguItems = _sigunguOptions;
    final dongItems = _dongOptions;

    return Container(
      color: kSurface,
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
      child: Row(
        children: [
          // ── 지역 드롭다운 3개 ───────────────────────────────────────────
          _FilterDropdown<String?>(
            value: _sido,
            hint: '시/도',
            items: [
              const DropdownMenuItem(value: null, child: Text('전국')),
              ..._kSidoList.map((s) => DropdownMenuItem(value: s, child: Text(s))),
            ],
            onChanged: (v) => _onSidoChanged(v, uid),
          ),
          const SizedBox(width: 6),
          _FilterDropdown<String?>(
            value: _sigungu,
            hint: '시/군/구',
            enabled: _sido != null,
            loading: _optionsLoading,
            items: [
              const DropdownMenuItem(value: null, child: Text('전체')),
              ...sigunguItems.map((s) => DropdownMenuItem(value: s, child: Text(s))),
            ],
            onChanged: sigunguItems.isEmpty && !_optionsLoading
                ? null
                : (v) => _onSigunguChanged(v, uid),
          ),
          const SizedBox(width: 6),
          _FilterDropdown<String?>(
            value: _dong,
            hint: '읍/면/동',
            enabled: _sigungu != null && dongItems.isNotEmpty,
            items: [
              const DropdownMenuItem(value: null, child: Text('전체')),
              ...dongItems.map((s) => DropdownMenuItem(value: s, child: Text(s))),
            ],
            onChanged: dongItems.isEmpty
                ? null
                : (v) => _onDongChanged(v, uid),
          ),
          const Spacer(),
          // ── 연도 드롭다운 ──────────────────────────────────────────────
          _FilterDropdown<int?>(
            value: _year,
            hint: '연도',
            items: [
              const DropdownMenuItem(value: null, child: Text('전체')),
              ..._kYearList.map(
                (y) => DropdownMenuItem(value: y, child: Text('$y년')),
              ),
            ],
            onChanged: (v) => _onYearChanged(v, uid),
          ),
        ],
      ),
    );
  }

  // ── 목록 ───────────────────────────────────────────────────────────────────

  Widget _buildList() {
    final docs = _filteredDocs;

    if (docs.isEmpty && !_isLoading && !_hasMore) return _buildEmptyState();
    if (docs.isEmpty && _isLoading) {
      return Center(child: CircularProgressIndicator(color: kPrimary));
    }

    return ListView.builder(
      controller: _scrollCtrl,
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 100),
      itemCount: docs.length + (_isLoading && _hasMore ? 1 : 0),
      itemBuilder: (ctx, i) {
        if (i == docs.length) {
          return Padding(
            padding: const EdgeInsets.symmetric(vertical: 20),
            child: Center(
              child: CircularProgressIndicator(strokeWidth: 2, color: kPrimary),
            ),
          );
        }
        return _buildNoteCard(docs[i].id, docs[i].data());
      },
    );
  }

  // ── 노트 카드 ──────────────────────────────────────────────────────────────

  Widget _buildNoteCard(String docId, Map<String, dynamic> data) {
    final title = data['title'] as String? ?? '(제목 없음)';
    final address = data['address'] as String? ?? '';
    final review = data['review'] as String? ?? '';
    final mediaUrls =
        (data['mediaUrls'] as List<dynamic>?)?.whereType<String>().toList() ?? [];
    final createdAt = data['createdAt'] as Timestamp?;
    final dateStr = createdAt != null ? _formatDate(createdAt.toDate()) : '';

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        color: kSurface,
        borderRadius: BorderRadius.circular(16),
        boxShadow: const [
          BoxShadow(color: Color(0x0F000000), blurRadius: 16, offset: Offset(0, 4)),
        ],
      ),
      child: InkWell(
        onTap: () async {
          final changed = await Navigator.push<bool>(
            context,
            MaterialPageRoute(
              builder: (_) => ImjangNoteDetailScreen(
                text: review,
                mediaUrls: mediaUrls,
                createdAt: createdAt?.toDate() ?? DateTime.now(),
                docId: docId,
                aptName: title,
              ),
            ),
          );
          if (changed == true && mounted && _loadedForUid != null) {
            _reset(_loadedForUid!);
          }
        },
        borderRadius: BorderRadius.circular(16),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 썸네일
            Container(
              width: 88,
              height: 88,
              margin: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: kBackground,
                borderRadius: BorderRadius.circular(12),
              ),
              child: mediaUrls.isNotEmpty
                  ? ClipRRect(
                      borderRadius: BorderRadius.circular(12),
                      child: CachedNetworkImage(
                        imageUrl: mediaUrls.first,
                        fit: BoxFit.cover,
                        placeholder: (ctx, url) => Center(
                          child: CircularProgressIndicator(
                              strokeWidth: 2, color: kPrimary),
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
                    if (address.isNotEmpty)
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 7, vertical: 3),
                        decoration: BoxDecoration(
                          color: kPrimaryLight,
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
                    Text(
                      review,
                      style: const TextStyle(
                          fontSize: 12, color: kTextMuted, height: 1.45),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 9),
                    Row(
                      children: [
                        Icon(Icons.calendar_today_outlined,
                            size: 11, color: kTextMuted),
                        const SizedBox(width: 4),
                        Text(
                          dateStr,
                          style: TextStyle(
                              fontSize: 11,
                              color: kTextMuted,
                              fontWeight: FontWeight.w500),
                        ),
                        if (mediaUrls.isNotEmpty) ...[
                          const SizedBox(width: 8),
                          Icon(Icons.photo_outlined,
                              size: 11, color: kTextMuted),
                          const SizedBox(width: 3),
                          Text('${mediaUrls.length}',
                              style: TextStyle(
                                  fontSize: 11, color: kTextMuted)),
                        ],
                        const Spacer(),
                        Icon(Icons.chevron_right_rounded,
                            size: 18, color: kTextMuted),
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
          color: kTextMuted,
          size: 24,
        ),
        const SizedBox(height: 2),
        Text('사진 없음',
            style: TextStyle(
                color: kTextMuted, fontSize: 9, fontWeight: FontWeight.w500)),
      ],
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
              color: kPrimaryLight,
              shape: BoxShape.circle,
            ),
            child: const Icon(Icons.edit_note_rounded,
                size: 40, color: kPrimary),
          ),
          const SizedBox(height: 20),
          const Text('임장 노트가 없어요',
              style: TextStyle(
                  fontSize: 17,
                  fontWeight: FontWeight.w700,
                  color: kTextDark,
                  letterSpacing: -0.3)),
          const SizedBox(height: 8),
          const Text(
            '직접 방문한 매물의 현장 감상을\n노트로 기록해 보세요.',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 13.5, color: kTextMuted, height: 1.6),
          ),
          const SizedBox(height: 32),
          ElevatedButton.icon(
            onPressed: _openWriteScreen,
            icon: const Icon(Icons.edit_rounded, size: 18),
            label: const Text('첫 번째 노트 작성하기'),
            style: ElevatedButton.styleFrom(minimumSize: const Size(200, 48)),
          ),
        ],
      ),
    );
  }

  Widget _buildLoginPrompt() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(
            width: 80,
            height: 80,
            decoration: BoxDecoration(color: kPrimaryLight, shape: BoxShape.circle),
            child: const Icon(Icons.lock_outline_rounded, size: 36, color: kPrimary),
          ),
          const SizedBox(height: 20),
          const Text('로그인이 필요합니다',
              style: TextStyle(
                  fontSize: 17,
                  fontWeight: FontWeight.w700,
                  color: kTextDark,
                  letterSpacing: -0.3)),
          const SizedBox(height: 8),
          const Text(
            '임장 노트를 작성하고 확인하려면\n로그인해 주세요.',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 13.5, color: kTextMuted, height: 1.6),
          ),
        ],
      ),
    );
  }

  String _formatDate(DateTime dt) =>
      '${dt.year}.${dt.month.toString().padLeft(2, '0')}.${dt.day.toString().padLeft(2, '0')}';
}

// ─────────────────────────────────────────────────────────────────────────────
// 드롭다운 필터 위젯
// ─────────────────────────────────────────────────────────────────────────────

class _FilterDropdown<T> extends StatelessWidget {
  const _FilterDropdown({
    required this.value,
    required this.hint,
    required this.items,
    required this.onChanged,
    this.enabled = true,
    this.loading = false,
  });

  final T value;
  final String hint;
  final List<DropdownMenuItem<T>> items;
  final ValueChanged<T?>? onChanged;
  final bool enabled;
  final bool loading;

  @override
  Widget build(BuildContext context) {
    final isActive = enabled && !loading;
    final hasValue = value != null;

    return Container(
      height: 34,
      padding: const EdgeInsets.symmetric(horizontal: 10),
      decoration: BoxDecoration(
        color: hasValue ? kPrimary : kSurface,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: hasValue ? kPrimary : kBorderColor,
        ),
      ),
      child: loading
          ? const SizedBox(
              width: 14,
              height: 14,
              child: Center(
                child: CircularProgressIndicator(strokeWidth: 1.5, color: kPrimary),
              ),
            )
          : DropdownButtonHideUnderline(
              child: DropdownButton<T>(
                value: value,
                hint: Text(
                  hint,
                  style: TextStyle(
                    fontSize: 12,
                    color: isActive ? kTextMuted : Colors.grey.shade400,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                items: items,
                onChanged: isActive ? onChanged : null,
                isDense: true,
                icon: Icon(
                  Icons.keyboard_arrow_down_rounded,
                  size: 16,
                  color: hasValue
                      ? Colors.white
                      : (isActive ? kTextMuted : Colors.grey.shade400),
                ),
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: hasValue ? Colors.white : kTextDark,
                ),
                dropdownColor: Colors.white,
                borderRadius: BorderRadius.circular(10),
                menuMaxHeight: 260,
              ),
            ),
    );
  }
}
