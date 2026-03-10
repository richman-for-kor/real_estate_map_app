import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import '../main.dart'
    show
        kPrimary,
        kPrimaryLight,
        kSecondary,
        kBackground,
        kSurface,
        kTextDark,
        kTextMuted;
import '../services/auth_service.dart';
import '../services/news_service.dart';
import '../services/public_data_service.dart';
import 'favorite_list_screen.dart';
import 'login_screen.dart';
import 'news_webview_screen.dart';

// ─── 로컬 팔레트 별칭 (iOS 스타일) ───────────────────────────────────────────
const _kPageBg = kBackground; // F5F7FA — 거의 흰색 배경
const _kCardBg = kSurface;   // FFFFFF — 순백 카드

// ─── 시세 조회 대상 지역 (법정동코드 5자리 + 대표 좌표) ──────────────────────────
// 법정동코드 출처: 행정표준코드관리시스템 (https://www.code.go.kr)
const _kStatRegions = [
  (area: '강남구', lawdCd: '11680', lat: 37.5172, lng: 127.0473),
  (area: '마포구', lawdCd: '11440', lat: 37.5523, lng: 126.9087),
  (area: '송파구', lawdCd: '11710', lat: 37.5145, lng: 127.1059),
  (area: '용산구', lawdCd: '11170', lat: 37.5320, lng: 126.9904),
  (area: '성동구', lawdCd: '11200', lat: 37.5635, lng: 127.0369),
  (area: '영등포', lawdCd: '11560', lat: 37.5264, lng: 126.8963),
  (area: '분당구', lawdCd: '41135', lat: 37.3825, lng: 127.1152),
];

/// 실거래가 API 조회 연월 문자열 (YYYYMM).
///
/// [monthOffset] 0 = 이번 달, -1 = 지난달 (폴백용).
String _dealYmd({int monthOffset = 0}) {
  final now = DateTime.now();
  final target = DateTime(now.year, now.month + monthOffset);
  return '${target.year}${target.month.toString().padLeft(2, '0')}';
}

/// 만원 단위 평균가 → "N.M억" 형식 표시 문자열.
///
/// 예: 234500만원 → "23.4억", 87000만원 → "8.7억", 9000만원 → "9000만"
String _formatAvgPrice(int priceManWon) {
  final eok = priceManWon ~/ 10000;
  final man = priceManWon % 10000;
  if (eok > 0) {
    final decimal = man ~/ 1000; // 억 아래 첫째 자리 (0~9)
    return decimal > 0 ? '$eok.$decimal억' : '$eok억';
  }
  return '${(priceManWon ~/ 100) * 100}만'; // 100만 단위 반올림
}

/// 지역별 평균 시세 결과 모델 (홈 화면 전용).
class _MarketStat {
  final String area;
  final String price;
  final int tradeCount; // API 응답 샘플 내 거래건수 (최대 30건)
  final bool isError;

  const _MarketStat({
    required this.area,
    required this.price,
    required this.tradeCount,
    this.isError = false,
  });

  factory _MarketStat.error(String area) =>
      _MarketStat(area: area, price: '-', tradeCount: 0, isError: true);
}

/// 홈 탭 — iOS Large Title + CustomScrollView/Sliver 아키텍처.
///
/// [구조]
///   RefreshIndicator
///   └─ CustomScrollView (AlwaysScrollableScrollPhysics)
///        ├─ SliverAppBar       : pinned+floating "Large Title" 애니메이션
///        ├─ SliverToBoxAdapter : Auth 카드
///        ├─ SliverToBoxAdapter : 퀵 메뉴
///        ├─ SliverToBoxAdapter : 지역별 매매가 (가로 스크롤)
///        ├─ SliverToBoxAdapter : 뉴스 섹션 헤더
///        └─ SliverList        : 뉴스 카드 피드
///
/// [Pull-to-Refresh]
///   RefreshIndicator가 CustomScrollView 전체를 감싸므로
///   뉴스뿐 아니라 시세 등 모든 섹션 새로고침 트리거 가능.
class HomeScreen extends StatefulWidget {
  const HomeScreen({
    super.key,
    required this.onTabSwitch,
    this.onMapRegionTap,
  });

  /// 0=홈, 1=지도, 2=임장노트, 3=내정보
  final void Function(int) onTabSwitch;

  /// 지역별 매매가 카드 탭 시 지도 이동 요청 콜백 (lat, lng)
  final void Function(double lat, double lng)? onMapRegionTap;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  // [중요] non-final — _refresh()에서 새 Future로 재할당
  late Future<List<NewsItem>> _newsFuture;

  /// 지역별 시세 캐시. null = 최초 로드 전, 빈 리스트 = 전체 오류.
  List<_MarketStat>? _statItems;
  bool _statsLoading = false;

  @override
  void initState() {
    super.initState();
    _newsFuture = NewsService().fetchNews();
    _loadStats();
  }

  // ── 시세 데이터 로드 ────────────────────────────────────────────────────────

  /// 오늘 날짜 기반 Firestore 캐시 문서 ID (YYYYMMDD).
  String get _todayCacheId {
    final now = DateTime.now();
    return '${now.year}${now.month.toString().padLeft(2, '0')}${now.day.toString().padLeft(2, '0')}';
  }

  /// 전체 지역 시세를 로드합니다.
  ///
  /// [force] = false: Firestore 일일 캐시 우선 사용 → 없으면 API 호출 후 저장.
  /// [force] = true : 캐시를 무시하고 API 재호출 후 캐시 갱신 (Pull-to-Refresh).
  Future<void> _loadStats({bool force = false}) async {
    if (_statItems != null && !force) return;
    if (_statsLoading) return;
    setState(() => _statsLoading = true);
    try {
      // 1. Firestore 일일 캐시 확인
      if (!force) {
        final cached = await _loadCachedStats();
        if (cached != null && mounted) {
          setState(() {
            _statItems = cached;
            _statsLoading = false;
          });
          return;
        }
      }

      // 2. 공공데이터 API 호출 — 최근 3개월 병렬 조회
      final ymds = [
        _dealYmd(),
        _dealYmd(monthOffset: -1),
        _dealYmd(monthOffset: -2),
      ];
      final results = await Future.wait(
        _kStatRegions.map((r) => _fetchRegionStat(r.area, r.lawdCd, ymds)),
      );

      // 3. Firestore에 일일 캐시 저장 (실패해도 UI에는 영향 없음)
      _saveCachedStats(results);

      if (mounted) {
        debugPrint('[HomeScreen] _loadStats 완료 — ${results.length}개 지역');
        setState(() {
          _statItems = results;
          _statsLoading = false;
        });
      }
    } catch (e, st) {
      debugPrint('[HomeScreen] _loadStats 예외: $e\n$st');
      if (mounted) setState(() => _statsLoading = false);
    }
  }

  /// 단일 지역의 최근 3개월 평균 거래가를 계산합니다.
  ///
  /// [ymds]: 조회할 YYYYMM 문자열 목록 (3개월치).
  /// 월별 최대 100건씩 조회, 전체 유효 거래 기준으로 평균을 계산합니다.
  Future<_MarketStat> _fetchRegionStat(
    String area,
    String lawdCd,
    List<String> ymds,
  ) async {
    try {
      final svc = const PublicDataService();
      final monthResults = await Future.wait(
        ymds.map((ymd) => svc.fetchAptTrades(
              lawdCd: lawdCd,
              dealYmd: ymd,
              numOfRows: 100,
            )),
      );
      final valid = monthResults
          .expand((r) => r.records)
          .where((r) => r.price > 0)
          .toList();
      if (valid.isEmpty) return _MarketStat.error(area);
      final total = valid.map((r) => r.price).reduce((a, b) => a + b);
      return _MarketStat(
        area: area,
        price: _formatAvgPrice(total ~/ valid.length),
        tradeCount: valid.length,
      );
    } catch (e, st) {
      debugPrint('[HomeScreen] _fetchRegionStat($area) 오류: $e\n$st');
      return _MarketStat.error(area);
    }
  }

  /// Firestore에서 오늘의 시세 캐시를 읽습니다.
  /// 없거나 파싱 실패 시 null 반환.
  Future<List<_MarketStat>?> _loadCachedStats() async {
    try {
      final doc = await FirebaseFirestore.instance
          .collection('market_stats_cache')
          .doc(_todayCacheId)
          .get();
      if (!doc.exists) return null;
      final statsData = doc.data()?['stats'] as List<dynamic>?;
      if (statsData == null || statsData.length != _kStatRegions.length) {
        return null;
      }
      debugPrint('[HomeScreen] 시세 캐시 HIT — $_todayCacheId');
      return statsData.map((s) {
        final map = s as Map<String, dynamic>;
        return _MarketStat(
          area: map['area'] as String,
          price: map['price'] as String,
          tradeCount: (map['tradeCount'] as num).toInt(),
          isError: map['isError'] as bool? ?? false,
        );
      }).toList();
    } catch (e) {
      debugPrint('[HomeScreen] 시세 캐시 로드 실패: $e');
      return null;
    }
  }

  /// 오늘의 시세 결과를 Firestore에 저장합니다 (전체 사용자 공통).
  Future<void> _saveCachedStats(List<_MarketStat> stats) async {
    try {
      await FirebaseFirestore.instance
          .collection('market_stats_cache')
          .doc(_todayCacheId)
          .set({
        'createdAt': FieldValue.serverTimestamp(),
        'stats': stats
            .map((s) => {
                  'area': s.area,
                  'price': s.price,
                  'tradeCount': s.tradeCount,
                  'isError': s.isError,
                })
            .toList(),
      });
      debugPrint('[HomeScreen] 시세 캐시 저장 완료 — $_todayCacheId');
    } catch (e) {
      debugPrint('[HomeScreen] 시세 캐시 저장 실패 (무시): $e');
    }
  }

  Future<void> _refresh() async {
    final future = NewsService().fetchNews();
    setState(() => _newsFuture = future);
    _loadStats(force: true); // Pull-to-Refresh 시 시세도 새로고침
    try {
      await future;
    } catch (_) {}
  }

  // ── build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _kPageBg,
      body: RefreshIndicator(
        onRefresh: _refresh,
        color: kPrimary,
        displacement: 88,
        child: CustomScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          slivers: [
            // ① Large Title 앱바
            _buildSliverAppBar(),

            // ② Auth 카드 (로그인/비로그인 분기)
            _buildAuthSliver(),

            const SliverToBoxAdapter(child: SizedBox(height: 24)),

            // ③ 퀵 메뉴 (4칸 그리드)
            _buildQuickMenuSliver(),

            const SliverToBoxAdapter(child: SizedBox(height: 28)),

            // ④ 지역별 평균 매매가 (가로 스크롤)
            _buildMarketStatsSliver(),

            const SliverToBoxAdapter(child: SizedBox(height: 28)),

            // ⑤ 뉴스 섹션 헤더
            _buildNewsSectionHeaderSliver(),

            const SliverToBoxAdapter(child: SizedBox(height: 12)),

            // ⑥ 뉴스 피드 (SliverList)
            _buildNewsSliver(),

            // ⑦ 하단 여백
            const SliverToBoxAdapter(child: SizedBox(height: 48)),
          ],
        ),
      ),
    );
  }

  // ─────────────────────────────────────────────────────────────────────────
  // ① SliverAppBar — iOS Large Title 애니메이션
  // ─────────────────────────────────────────────────────────────────────────

  Widget _buildSliverAppBar() {
    return SliverAppBar(
      pinned: true,
      floating: true,
      // Large Title 영역 확보 (iOS 기본값 ~96pt)
      expandedHeight: 96,
      backgroundColor: _kCardBg,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      // 콘텐츠가 스크롤되어 내려올 때 생기는 얇은 구분선
      scrolledUnderElevation: 0.6,
      shadowColor: Colors.black12,
      flexibleSpace: FlexibleSpaceBar(
        // titlePadding: 접힌 상태에서의 위치 기준점 (leading 20, bottom 14)
        titlePadding: const EdgeInsetsDirectional.only(start: 20, bottom: 14),
        // 1.0이면 접힌 크기와 동일 — 1.7배 확대해 Large Title 구현
        expandedTitleScale: 1.7,
        title: Row(
          mainAxisSize: MainAxisSize.min,
          children: const [
            Icon(Icons.home_rounded, color: kPrimary, size: 17),
            SizedBox(width: 4),
            Text(
              '집로그',
              style: TextStyle(
                color: kTextDark,
                fontSize: 17,
                fontWeight: FontWeight.w800,
                letterSpacing: -0.7,
              ),
            ),
          ],
        ),
        background: const ColoredBox(color: _kCardBg),
      ),
      actions: [
        Padding(
          padding: const EdgeInsets.only(right: 4),
          child: IconButton(
            icon: const Icon(
              Icons.notifications_outlined,
              color: kTextDark,
              size: 24,
            ),
            onPressed: () => _showNotificationSheet(context),
          ),
        ),
      ],
    );
  }

  // ─────────────────────────────────────────────────────────────────────────
  // ② Auth 카드
  // ─────────────────────────────────────────────────────────────────────────

  Widget _buildAuthSliver() {
    return SliverToBoxAdapter(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
        child: StreamBuilder<User?>(
          stream: AuthService().authStateChanges,
          builder: (context, snapshot) {
            final user = snapshot.data;
            return user != null
                ? _WelcomeCard(
                    user: user,
                    onTabSwitch: widget.onTabSwitch,
                    onNotificationTap: () => _showNotificationSheet(context),
                  )
                : _GuestCard(onTap: () => Navigator.push(
                      context,
                      MaterialPageRoute(
                          builder: (_) => const LoginScreen()),
                    ));
          },
        ),
      ),
    );
  }

  // ─────────────────────────────────────────────────────────────────────────
  // ③ 퀵 메뉴
  // ─────────────────────────────────────────────────────────────────────────

  Widget _buildQuickMenuSliver() {
    final items = [
      _QuickItem(
        icon: Icons.edit_note_rounded,
        color: kPrimary,
        label: '임장노트',
        onTap: () => widget.onTabSwitch(2),
      ),
      _QuickItem(
        icon: Icons.map_rounded,
        color: kPrimary,
        label: '지도 보기',
        onTap: () => widget.onTabSwitch(1),
      ),
      _QuickItem(
        icon: Icons.home_work_rounded,
        color: kPrimary,
        label: '청약 정보',
        onTap: () => ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('청약 정보 기능 준비 중입니다.'),
            margin: EdgeInsets.all(16),
          ),
        ),
      ),
      _QuickItem(
        icon: Icons.favorite_rounded,
        color: kPrimary,
        label: '관심매물',
        onTap: () => Navigator.push(
          context,
          MaterialPageRoute(builder: (_) => const FavoriteListScreen()),
        ),
      ),
    ];

    return SliverToBoxAdapter(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 18, horizontal: 4),
          decoration: BoxDecoration(
            color: _kCardBg,
            borderRadius: BorderRadius.circular(20),
            boxShadow: const [
              BoxShadow(
                color: Color(0x0F000000),
                blurRadius: 16,
                offset: Offset(0, 4),
              ),
            ],
          ),
          child: Row(
            children: items
                .map((e) => Expanded(child: _QuickMenuCell(item: e)))
                .toList(),
          ),
        ),
      ),
    );
  }

  // ─────────────────────────────────────────────────────────────────────────
  // ④ 지역별 매매가
  // ─────────────────────────────────────────────────────────────────────────

  Widget _buildMarketStatsSliver() {
    return SliverToBoxAdapter(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 섹션 헤더
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 14),
            child: Row(
              children: [
                const Expanded(
                  child: Text(
                    '지역별 평균 매매가',
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w800,
                      color: kTextDark,
                      letterSpacing: -0.6,
                    ),
                  ),
                ),
                Tooltip(
                  message: '최근 3개월 동안의 실거래 평균 매매가 입니다.',
                  triggerMode: TooltipTriggerMode.tap,
                  showDuration: const Duration(seconds: 3),
                  padding: const EdgeInsets.symmetric(
                      horizontal: 12, vertical: 8),
                  decoration: BoxDecoration(
                    color: kPrimary.withValues(alpha: 0.92),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  textStyle: const TextStyle(
                    color: Colors.white,
                    fontSize: 12,
                  ),
                  child: Container(
                    width: 18,
                    height: 18,
                    decoration: BoxDecoration(
                      border: Border.all(color: kTextMuted, width: 1.2),
                      shape: BoxShape.circle,
                    ),
                    child: const Center(
                      child: Text(
                        'i',
                        style: TextStyle(
                          fontSize: 10,
                          fontWeight: FontWeight.w700,
                          color: kTextMuted,
                          height: 1,
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
          // 가로 스크롤 카드 열
          SizedBox(
            height: 114,
            child: _statsLoading && _statItems == null
                // 로딩 중: 스켈레톤 플레이스홀더
                ? ListView.builder(
                    scrollDirection: Axis.horizontal,
                    padding: const EdgeInsets.fromLTRB(16, 0, 8, 4),
                    itemCount: _kStatRegions.length,
                    itemBuilder: (_, i) => _StatCardSkeleton(
                      isLast: i == _kStatRegions.length - 1,
                    ),
                  )
                // 로드 완료: 실제 데이터
                : ListView.builder(
                    scrollDirection: Axis.horizontal,
                    padding: const EdgeInsets.fromLTRB(16, 0, 8, 4),
                    itemCount: (_statItems ?? []).length,
                    itemBuilder: (_, i) {
                      final items = _statItems!;
                      final s = items[i];
                      final region = _kStatRegions[i];
                      return _StatCard(
                        area: s.area,
                        price: s.price,
                        change: s.isError ? '-' : '${s.tradeCount}건',
                        isNeutral: true,
                        isLast: i == items.length - 1,
                        onTap: widget.onMapRegionTap != null
                            ? () {
                                widget.onTabSwitch(1);
                                widget.onMapRegionTap!(region.lat, region.lng);
                              }
                            : null,
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }

  // ─────────────────────────────────────────────────────────────────────────
  // ⑤ 뉴스 섹션 헤더
  // ─────────────────────────────────────────────────────────────────────────

  Widget _buildNewsSectionHeaderSliver() {
    return SliverToBoxAdapter(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 16, 0),
        child: Row(
          children: [
            const Expanded(
              child: Text(
                '오늘의 부동산 뉴스',
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w800,
                  color: kTextDark,
                  letterSpacing: -0.6,
                ),
              ),
            ),
            TextButton(
              onPressed: _openNaverLandNews,
              style: TextButton.styleFrom(
                padding:
                    const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                minimumSize: Size.zero,
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                foregroundColor: kSecondary,
                textStyle: const TextStyle(
                    fontSize: 12, fontWeight: FontWeight.w600),
              ),
              child: const Row(
                children: [
                  Text('더보기'),
                  Icon(Icons.chevron_right_rounded, size: 16),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ─────────────────────────────────────────────────────────────────────────
  // ⑥ 뉴스 SliverList
  // ─────────────────────────────────────────────────────────────────────────

  Widget _buildNewsSliver() {
    return FutureBuilder<List<NewsItem>>(
      future: _newsFuture,
      builder: (context, snapshot) {
        // 로딩
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const SliverToBoxAdapter(
            child: Padding(
              padding: EdgeInsets.symmetric(vertical: 64),
              child: Center(
                child: CircularProgressIndicator(
                    color: kPrimary, strokeWidth: 2.5),
              ),
            ),
          );
        }

        // 에러
        if (snapshot.hasError) {
          return SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: _ErrorCard(onRetry: _refresh),
            ),
          );
        }

        // 빈 결과
        final items = snapshot.data ?? [];
        if (items.isEmpty) {
          return const SliverToBoxAdapter(
            child: Padding(
              padding: EdgeInsets.symmetric(vertical: 40),
              child: Center(
                child: Text(
                  '뉴스가 없습니다.',
                  style: TextStyle(fontSize: 13, color: kTextMuted),
                ),
              ),
            ),
          );
        }

        // 뉴스 카드 목록
        return SliverPadding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          sliver: SliverList(
            delegate: SliverChildBuilderDelegate(
              (context, index) => Padding(
                padding: EdgeInsets.only(
                    bottom: index < items.length - 1 ? 10 : 0),
                child: _NewsCard(
                  item: items[index],
                  onTap: () => _openUrl(items[index].openUrl),
                ),
              ),
              childCount: items.length,
            ),
          ),
        );
      },
    );
  }

  // ─────────────────────────────────────────────────────────────────────────
  // URL 열기
  // ─────────────────────────────────────────────────────────────────────────

  Future<void> _openUrl(String rawUrl) async {
    if (rawUrl.isEmpty) return;
    final uri = Uri.tryParse(rawUrl);
    if (uri == null || !uri.hasScheme) return;
    if (!mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (_) => NewsWebviewScreen(url: rawUrl),
      ),
    );
  }

  void _showNotificationSheet(BuildContext context) {
    showModalBottomSheet(
      context: context,
      backgroundColor: _kCardBg,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 14, 20, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 36,
                height: 4,
                decoration: BoxDecoration(
                  color: const Color(0xFFDDE3EA),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const SizedBox(height: 20),
              const Icon(Icons.notifications_none_rounded,
                  size: 44, color: kTextMuted),
              const SizedBox(height: 12),
              const Text(
                '알림이 없습니다',
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                  color: kTextDark,
                ),
              ),
              const SizedBox(height: 6),
              const Text(
                '새 알림이 오면 여기에 표시됩니다.',
                style: TextStyle(fontSize: 12, color: kTextMuted),
              ),
              const SizedBox(height: 8),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _openNaverLandNews() async {
    if (!mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (_) => const NewsWebviewScreen(
          url: 'https://land.naver.com/news/',
          title: '부동산 뉴스 더보기',
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// 서브 위젯들 (추출로 build() 가독성 확보)
// ─────────────────────────────────────────────────────────────────────────────

/// 로그인 상태 환영 카드 — 화이트 배경 + 은은한 장식 원.
class _WelcomeCard extends StatefulWidget {
  const _WelcomeCard({
    required this.user,
    required this.onTabSwitch,
    required this.onNotificationTap,
  });
  final User user;
  final void Function(int) onTabSwitch;
  final VoidCallback onNotificationTap;

  @override
  State<_WelcomeCard> createState() => _WelcomeCardState();
}

class _WelcomeCardState extends State<_WelcomeCard> {
  int _imjangCount = 0;
  int _favoriteCount = 0;

  @override
  void initState() {
    super.initState();
    _loadCounts();
  }

  Future<void> _loadCounts() async {
    final uid = widget.user.uid;
    try {
      final results = await Future.wait([
        FirebaseFirestore.instance
            .collection('imjang_records')
            .where('uid', isEqualTo: uid)
            .count()
            .get(),
        FirebaseFirestore.instance
            .collection('users')
            .doc(uid)
            .collection('favorites')
            .count()
            .get(),
      ]);
      if (mounted) {
        setState(() {
          _imjangCount = results[0].count ?? 0;
          _favoriteCount = results[1].count ?? 0;
        });
      }
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final name =
        widget.user.displayName ?? widget.user.email?.split('@').first ?? '회원';
    return Container(
      decoration: BoxDecoration(
        color: _kCardBg,
        borderRadius: BorderRadius.circular(20),
        boxShadow: const [
          BoxShadow(
            color: Color(0x0F000000),
            blurRadius: 16,
            offset: Offset(0, 4),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(20),
        child: Stack(
          children: [
            // 우측 상단 장식 원 (은은한 kPrimary 톤)
            Positioned(
              right: -28,
              top: -28,
              child: Container(
                width: 110,
                height: 110,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: kPrimary.withValues(alpha: 0.06),
                ),
              ),
            ),
            Positioned(
              right: 20,
              bottom: -18,
              child: Container(
                width: 72,
                height: 72,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: kSecondary.withValues(alpha: 0.07),
                ),
              ),
            ),
            // 카드 본문
            Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '안녕하세요,',
                    style: TextStyle(
                      color: kTextMuted,
                      fontSize: 13,
                      fontWeight: FontWeight.w400,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.baseline,
                    textBaseline: TextBaseline.alphabetic,
                    children: [
                      GestureDetector(
                        onTap: () => widget.onTabSwitch(3),
                        child: Text(
                          '$name님',
                          style: const TextStyle(
                            color: kTextDark,
                            fontSize: 23,
                            fontWeight: FontWeight.w800,
                            letterSpacing: -0.8,
                          ),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Text(
                        '임장 $_imjangCount · 관심 $_favoriteCount · 알림 0',
                        style: TextStyle(
                          color: kTextMuted,
                          fontSize: 12,
                          fontWeight: FontWeight.w400,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _MiniStat extends StatelessWidget {
  const _MiniStat({
    required this.value,
    required this.label,
    this.onTap,
  });
  final String value;
  final String label;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: GestureDetector(
        onTap: onTap,
        behavior: HitTestBehavior.opaque,
        child: Column(
          children: [
            Text(
              value,
              style: const TextStyle(
                color: kTextDark,
                fontSize: 20,
                fontWeight: FontWeight.w800,
                letterSpacing: -0.5,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              label,
              style: const TextStyle(color: kTextMuted, fontSize: 11),
            ),
          ],
        ),
      ),
    );
  }
}

/// 비로그인 상태 게스트 카드 — 흰색 카드 + CTA.
class _GuestCard extends StatelessWidget {
  const _GuestCard({required this.onTap});
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(18),
        decoration: BoxDecoration(
          color: _kCardBg,
          borderRadius: BorderRadius.circular(20),
          boxShadow: const [
            BoxShadow(
              color: Color(0x0F000000),
              blurRadius: 16,
              offset: Offset(0, 4),
            ),
          ],
        ),
        child: Row(
          children: [
            Container(
              width: 52,
              height: 52,
              decoration: BoxDecoration(
                color: kPrimaryLight,
                shape: BoxShape.circle,
              ),
              child:
                  const Icon(Icons.login_rounded, color: kPrimary, size: 24),
            ),
            const SizedBox(width: 14),
            const Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '로그인하고 맞춤 정보 받기',
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w700,
                      color: kTextDark,
                      letterSpacing: -0.3,
                    ),
                  ),
                  SizedBox(height: 3),
                  Text(
                    '임장노트 · 관심매물 저장 · 맞춤 알림',
                    style: TextStyle(fontSize: 12, color: kTextMuted),
                  ),
                ],
              ),
            ),
            const Icon(Icons.chevron_right_rounded,
                color: kTextMuted, size: 22),
          ],
        ),
      ),
    );
  }
}

/// 퀵 메뉴 단일 셀.
class _QuickMenuCell extends StatelessWidget {
  const _QuickMenuCell({required this.item});
  final _QuickItem item;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: item.onTap,
      behavior: HitTestBehavior.opaque,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 56,
              height: 56,
              decoration: BoxDecoration(
                color: kPrimaryLight,
                borderRadius: BorderRadius.circular(18),
              ),
              child: Icon(item.icon, color: item.color, size: 26),
            ),
            const SizedBox(height: 8),
            Text(
              item.label,
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontSize: 11.5,
                fontWeight: FontWeight.w600,
                color: kTextDark,
                letterSpacing: -0.1,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 지역별 시세 카드 (가로 스크롤).
///
/// [isNeutral] = true : 화살표 없이 회색 배지로 표시 (거래건수 등 중립 정보용).
/// [isNeutral] = false: [isUp]에 따라 빨강(상승) / 파랑(하락) 배지 표시.
class _StatCard extends StatelessWidget {
  const _StatCard({
    required this.area,
    required this.price,
    required this.change,
    this.isNeutral = false,
    this.isLast = false,
    this.onTap,
  });

  final String area;
  final String price;
  final String change;
  /// true이면 화살표 없이 회색 배지 표시.
  /// false이면 빨간 상승 배지 표시 (향후 전월 대비 데이터 연동 시 활용).
  final bool isNeutral;
  final bool isLast;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final Color changeColor;
    final Color changeBg;
    if (isNeutral) {
      changeColor = kTextMuted;
      changeBg = const Color(0xFFF0F2F8);
    } else {
      changeColor = const Color(0xFFE53935);
      changeBg = const Color(0xFFFFF0F0);
    }

    return GestureDetector(
      onTap: onTap,
      child: Container(
      width: 144,
      margin: EdgeInsets.only(right: isLast ? 0 : 10),
      padding: const EdgeInsets.fromLTRB(14, 13, 14, 13),
      decoration: BoxDecoration(
        color: _kCardBg,
        borderRadius: BorderRadius.circular(18),
        boxShadow: const [
          BoxShadow(
            color: Color(0x0F000000),
            blurRadius: 16,
            offset: Offset(0, 4),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          // 지역명
          Text(
            area,
            style: const TextStyle(
              fontSize: 11.5,
              fontWeight: FontWeight.w500,
              color: kTextMuted,
            ),
          ),
          // 평균 매매가
          Text(
            price,
            style: const TextStyle(
              fontSize: 21,
              fontWeight: FontWeight.w800,
              color: kTextDark,
              letterSpacing: -0.6,
            ),
          ),
          // 배지 (변동률 또는 거래건수)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
            decoration: BoxDecoration(
              color: changeBg,
              borderRadius: BorderRadius.circular(6),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (!isNeutral) ...[
                  const Icon(Icons.arrow_upward_rounded,
                      size: 10, color: Color(0xFFE53935)),
                  const SizedBox(width: 2),
                ],
                Text(
                  change,
                  style: TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.w700,
                    color: changeColor,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
      ),
    );
  }
}

/// 시세 카드 로딩 스켈레톤.
class _StatCardSkeleton extends StatelessWidget {
  const _StatCardSkeleton({this.isLast = false});
  final bool isLast;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 144,
      margin: EdgeInsets.only(right: isLast ? 0 : 10),
      padding: const EdgeInsets.fromLTRB(14, 13, 14, 13),
      decoration: BoxDecoration(
        color: _kCardBg,
        borderRadius: BorderRadius.circular(18),
        boxShadow: const [
          BoxShadow(
            color: Color(0x0F000000),
            blurRadius: 16,
            offset: Offset(0, 4),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: const [
          _SkeletonBox(width: 44, height: 12),
          _SkeletonBox(width: 72, height: 22),
          _SkeletonBox(width: 52, height: 18),
        ],
      ),
    );
  }
}

/// 스켈레톤 사각형 블록.
class _SkeletonBox extends StatelessWidget {
  const _SkeletonBox({required this.width, required this.height});
  final double width;
  final double height;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: width,
      height: height,
      decoration: BoxDecoration(
        color: const Color(0xFFEEF0F5),
        borderRadius: BorderRadius.circular(6),
      ),
    );
  }
}

/// 뉴스 카드 (SliverList 아이템).
class _NewsCard extends StatelessWidget {
  const _NewsCard({required this.item, required this.onTap});
  final NewsItem item;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = _tagColors(item.tag);

    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: _kCardBg,
          borderRadius: BorderRadius.circular(16),
          boxShadow: const [
            BoxShadow(
              color: Color(0x0F000000),
              blurRadius: 16,
              offset: Offset(0, 4),
            ),
          ],
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 썸네일 (태그 기반 플랫 컬러)
            Container(
              width: 82,
              height: 82,
              decoration: BoxDecoration(
                color: _thumbColor(item.tag),
                borderRadius: BorderRadius.circular(14),
              ),
              child: Center(
                child: Icon(Icons.article_rounded,
                    color: _tagColors(item.tag).text.withValues(alpha: 0.5),
                    size: 26),
              ),
            ),
            const SizedBox(width: 12),
            // 콘텐츠
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // 메타 행: 태그 + 출처 + 시간
                  Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 7, vertical: 2),
                        decoration: BoxDecoration(
                          color: colors.bg,
                          borderRadius: BorderRadius.circular(5),
                        ),
                        child: Text(
                          item.tag,
                          style: TextStyle(
                            fontSize: 10,
                            fontWeight: FontWeight.w700,
                            color: colors.text,
                          ),
                        ),
                      ),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          item.source,
                          style: const TextStyle(
                              fontSize: 10, color: kTextMuted),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      Text(
                        item.relativeTime,
                        style: const TextStyle(
                            fontSize: 10, color: kTextMuted),
                      ),
                    ],
                  ),
                  const SizedBox(height: 7),
                  // 제목 (최대 2줄)
                  Text(
                    item.title,
                    style: const TextStyle(
                      fontSize: 13.5,
                      fontWeight: FontWeight.w700,
                      color: kTextDark,
                      letterSpacing: -0.2,
                      height: 1.35,
                    ),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 5),
                  // 요약 (최대 2줄)
                  Text(
                    item.description,
                    style: const TextStyle(
                      fontSize: 11.5,
                      color: kTextMuted,
                      height: 1.4,
                    ),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 뉴스 에러 카드.
class _ErrorCard extends StatelessWidget {
  const _ErrorCard({required this.onRetry});
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(28),
      decoration: BoxDecoration(
        color: _kCardBg,
        borderRadius: BorderRadius.circular(20),
        boxShadow: const [
          BoxShadow(
            color: Color(0x0F000000),
            blurRadius: 16,
            offset: Offset(0, 4),
          ),
        ],
      ),
      child: Column(
        children: [
          const Icon(Icons.wifi_off_rounded, size: 38, color: kTextMuted),
          const SizedBox(height: 12),
          const Text(
            '뉴스를 불러오지 못했습니다',
            style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w600,
                color: kTextDark),
          ),
          const SizedBox(height: 4),
          const Text(
            '네트워크 상태를 확인해 주세요.',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 12, color: kTextMuted),
          ),
          const SizedBox(height: 16),
          TextButton.icon(
            onPressed: onRetry,
            icon: const Icon(Icons.refresh_rounded, size: 16),
            label: const Text('다시 시도'),
            style:
                TextButton.styleFrom(foregroundColor: kSecondary),
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// 태그 색상 / 썸네일 그라디언트 헬퍼
// ─────────────────────────────────────────────────────────────────────────────

({Color bg, Color text}) _tagColors(String tag) {
  switch (tag) {
    case '청약':
      return (bg: kPrimaryLight, text: kPrimary);
    case '대출':
      return (bg: const Color(0xFFEDF7EE), text: const Color(0xFF16A34A));
    case '정책':
      return (bg: const Color(0xFFFFF7ED), text: const Color(0xFFD97706));
    case '전월세':
      return (bg: const Color(0xFFF5F0FF), text: const Color(0xFF7C3AED));
    default: // '시세'
      return (bg: kPrimaryLight, text: kPrimary);
  }
}

Color _thumbColor(String tag) {
  switch (tag) {
    case '청약':  return kPrimaryLight;
    case '대출':  return const Color(0xFFEDF7EE);
    case '정책':  return const Color(0xFFFFF7ED);
    case '전월세': return const Color(0xFFF5F0FF);
    default:      return kPrimaryLight; // '시세'
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// 내부 데이터 모델
// ─────────────────────────────────────────────────────────────────────────────

class _QuickItem {
  final IconData icon;
  final Color color;
  final String label;
  final VoidCallback onTap;

  _QuickItem({
    required this.icon,
    required this.color,
    required this.label,
    required this.onTap,
  });
}
