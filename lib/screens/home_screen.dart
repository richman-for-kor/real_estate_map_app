import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import '../main.dart'
    show
        kPrimary,
        kSecondary,
        kTextDark,
        kTextMuted;
import '../services/auth_service.dart';
import '../services/news_service.dart';
import '../services/public_data_service.dart';
import 'favorite_list_screen.dart';
import 'login_screen.dart';
import 'news_webview_screen.dart';

// ─── iOS 시스템 팔레트 ────────────────────────────────────────────────────────
const _kPageBg = Color(0xFFF2F2F7); // iOS Grouped Background
const _kCardBg = Colors.white;

// ─── 시세 조회 대상 지역 (법정동코드 5자리) ────────────────────────────────────
// 법정동코드 출처: 행정표준코드관리시스템 (https://www.code.go.kr)
const _kStatRegions = [
  (area: '강남구', lawdCd: '11680'), // 서울특별시 강남구
  (area: '마포구', lawdCd: '11440'), // 서울특별시 마포구
  (area: '송파구', lawdCd: '11710'), // 서울특별시 송파구
  (area: '용산구', lawdCd: '11170'), // 서울특별시 용산구
  (area: '성동구', lawdCd: '11200'), // 서울특별시 성동구
  (area: '영등포', lawdCd: '11560'), // 서울특별시 영등포구
  (area: '분당구', lawdCd: '41135'), // 경기도 성남시 분당구
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
  const HomeScreen({super.key, required this.onTabSwitch});

  /// 0=홈, 1=지도, 2=임장노트, 3=내정보
  final void Function(int) onTabSwitch;

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

  /// 전체 지역 시세를 [Future.wait]으로 병렬 호출 후 캐싱.
  ///
  /// [force] = false (기본): 캐시가 있으면 API를 호출하지 않습니다.
  /// [force] = true        : 캐시를 무시하고 재호출합니다 (Pull-to-Refresh 전용).
  Future<void> _loadStats({bool force = false}) async {
    if (_statItems != null && !force) return; // 캐시 HIT → 재호출 생략
    if (_statsLoading) return;               // 중복 호출 방지
    setState(() => _statsLoading = true);
    try {
      final ymd = _dealYmd();
      final results = await Future.wait(
        _kStatRegions.map((r) => _fetchRegionStat(r.area, r.lawdCd, ymd)),
      );
      if (mounted) {
        setState(() {
          _statItems = results;
          _statsLoading = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _statsLoading = false);
    }
  }

  /// 단일 지역의 평균 거래가를 계산합니다.
  ///
  /// 이번 달 거래 건수 0 → 지난달 데이터로 자동 폴백.
  /// 가격 합산은 PublicDataService 반환 최대 30건 샘플 기준입니다.
  Future<_MarketStat> _fetchRegionStat(
    String area,
    String lawdCd,
    String ymd,
  ) async {
    try {
      final svc = const PublicDataService();
      var data = await svc.fetchAptTrades(lawdCd: lawdCd, dealYmd: ymd);
      // 이번 달 데이터 없음(월초 등) → 지난달 폴백
      if (data.records.isEmpty) {
        data = await svc.fetchAptTrades(
          lawdCd: lawdCd,
          dealYmd: _dealYmd(monthOffset: -1),
        );
      }
      final valid = data.records.where((r) => r.price > 0).toList();
      if (valid.isEmpty) return _MarketStat.error(area);
      final total = valid.map((r) => r.price).reduce((a, b) => a + b);
      return _MarketStat(
        area: area,
        price: _formatAvgPrice(total ~/ valid.length),
        tradeCount: valid.length,
      );
    } catch (_) {
      return _MarketStat.error(area);
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
        title: const Text(
          '부동산 인사이트',
          style: TextStyle(
            color: kTextDark,
            fontSize: 17,
            fontWeight: FontWeight.w800,
            letterSpacing: -0.7,
          ),
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
            onPressed: () {},
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
                ? _WelcomeCard(user: user)
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
                Text(
                  '← 스와이프',
                  style: TextStyle(
                    fontSize: 11,
                    color: kTextMuted.withOpacity(0.5),
                  ),
                ),
              ],
            ),
          ),
          // 가로 스크롤 카드 열
          SizedBox(
            height: 104,
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
                      return _StatCard(
                        area: s.area,
                        price: s.price,
                        change: s.isError ? '-' : '${s.tradeCount}건',
                        isNeutral: true,
                        isLast: i == items.length - 1,
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
class _WelcomeCard extends StatelessWidget {
  const _WelcomeCard({required this.user});
  final User user;

  @override
  Widget build(BuildContext context) {
    final name =
        user.displayName ?? user.email?.split('@').first ?? '회원';
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: const Color(0xFFEEF0F3)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.03),
            blurRadius: 12,
            offset: const Offset(0, 3),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(22),
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
                  color: kPrimary.withOpacity(0.05),
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
                  color: kSecondary.withOpacity(0.06),
                ),
              ),
            ),
            // 카드 본문
            Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // 상단: 인삿말 + 프로필 아이콘
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
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
                            const SizedBox(height: 2),
                            Text(
                              '$name님',
                              style: const TextStyle(
                                color: kTextDark,
                                fontSize: 23,
                                fontWeight: FontWeight.w800,
                                letterSpacing: -0.8,
                              ),
                            ),
                          ],
                        ),
                      ),
                      Container(
                        width: 44,
                        height: 44,
                        decoration: BoxDecoration(
                          color: kPrimary.withOpacity(0.08),
                          shape: BoxShape.circle,
                        ),
                        child: const Icon(Icons.person_rounded,
                            color: kPrimary, size: 22),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  // 하단: 통계 행
                  Container(
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    decoration: BoxDecoration(
                      color: Colors.grey.shade50,
                      borderRadius: BorderRadius.circular(14),
                    ),
                    child: Row(
                      children: [
                        const _MiniStat(value: '3', label: '임장노트'),
                        Container(
                            width: 1,
                            height: 24,
                            color: Colors.grey.shade200),
                        const _MiniStat(value: '0', label: '관심매물'),
                        Container(
                            width: 1,
                            height: 24,
                            color: Colors.grey.shade200),
                        const _MiniStat(value: '0', label: '알림'),
                      ],
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

class _MiniStat extends StatelessWidget {
  const _MiniStat({required this.value, required this.label});
  final String value;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Expanded(
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
          borderRadius: BorderRadius.circular(22),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.05),
              blurRadius: 20,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        child: Row(
          children: [
            Container(
              width: 52,
              height: 52,
              decoration: BoxDecoration(
                color: kPrimary.withOpacity(0.08),
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
                color: item.color.withOpacity(0.09),
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
  });

  final String area;
  final String price;
  final String change;
  /// true이면 화살표 없이 회색 배지 표시.
  /// false이면 빨간 상승 배지 표시 (향후 전월 대비 데이터 연동 시 활용).
  final bool isNeutral;
  final bool isLast;

  @override
  Widget build(BuildContext context) {
    final Color changeColor;
    final Color changeBg;
    if (isNeutral) {
      changeColor = Colors.grey.shade500;
      changeBg = Colors.grey.shade100;
    } else {
      changeColor = const Color(0xFFE53935);
      changeBg = const Color(0xFFFFF0F0);
    }

    return Container(
      width: 144,
      margin: EdgeInsets.only(right: isLast ? 0 : 10),
      padding: const EdgeInsets.fromLTRB(14, 13, 14, 13),
      decoration: BoxDecoration(
        color: _kCardBg,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: const Color(0xFFEEF0F3)),
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
        border: Border.all(color: const Color(0xFFEEF0F3)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
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
        color: Colors.grey.shade200,
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
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: const Color(0xFFEEF0F3)),
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
                    color: _tagColors(item.tag).text.withOpacity(0.5),
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
      return (bg: const Color(0xFFEEF3FB), text: const Color(0xFF2563EB));
    case '대출':
      return (bg: const Color(0xFFEDF7EE), text: const Color(0xFF16A34A));
    case '정책':
      return (bg: const Color(0xFFFFF7ED), text: const Color(0xFFD97706));
    case '전월세':
      return (bg: const Color(0xFFF5F0FF), text: const Color(0xFF7C3AED));
    default: // '시세'
      return (bg: const Color(0xFFE8EEF5), text: kPrimary);
  }
}

Color _thumbColor(String tag) {
  switch (tag) {
    case '청약':  return const Color(0xFFEEF3FB);
    case '대출':  return const Color(0xFFEDF7EE);
    case '정책':  return const Color(0xFFFFF7ED);
    case '전월세': return const Color(0xFFF5F0FF);
    default:      return const Color(0xFFE8EEF5); // '시세'
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

