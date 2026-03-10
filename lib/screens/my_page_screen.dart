import 'package:cached_network_image/cached_network_image.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import '../main.dart'
    show
        kPrimary,
        kPrimaryLight,
        kSurface,
        kBackground,
        kBorderColor,
        kTextDark,
        kTextMuted;
import '../services/auth_service.dart';
import '../services/favorite_service.dart';
import '../services/recent_view_service.dart';
import '../widgets/image_viewer_popup.dart';
import 'edit_profile_screen.dart';
import 'favorite_list_screen.dart';
import 'imjang_screen.dart';
import 'login_screen.dart';
import 'recent_view_screen.dart';
import 'settings_screen.dart';

/// 내 정보 탭 화면.
///
/// [PM] Deferred Auth의 핵심 터치포인트.
/// 비로그인 상태에서도 앱을 탐색한 뒤 자연스럽게 로그인을 유도합니다.
/// 로그인 상태에서는 개인화된 프로필과 계정 관리 메뉴를 제공합니다.
///
/// [CTO] `authStateChanges` Stream을 여기서 구독하여
/// 로그인/로그아웃 시 UI가 자동으로 재빌드됩니다.
class MyPageScreen extends StatelessWidget {
  const MyPageScreen({super.key});

  @override
  Widget build(BuildContext context) {
    // [반응형] userChanges()는 authStateChanges()의 상위 집합입니다.
    // 로그인/로그아웃(authStateChanges) 이벤트 외에,
    // displayName·photoURL 등 프로필 변경 시에도 새 User를 emit합니다.
    return StreamBuilder<User?>(
      stream: FirebaseAuth.instance.userChanges(),
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Scaffold(
            backgroundColor: kBackground,
            body: Center(child: CircularProgressIndicator()),
          );
        }

        final user = snapshot.data;
        return user == null
            ? _GuestView()
            : _ProfileView(user: user);
      },
    );
  }
}

// ── 비로그인 뷰 ────────────────────────────────────────────────────────────────

/// 비로그인 상태 UI.
///
/// [UX/PM] "강제 로그인" 대신 앱의 가치를 먼저 보여준 뒤 로그인을 권유합니다.
/// 잠긴 기능들을 미리 보여줌으로써 로그인의 필요성을 자연스럽게 인식하게 합니다.
class _GuestView extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: kBackground,
      appBar: AppBar(
        title: const Text('내 정보'),
        backgroundColor: kSurface,
        elevation: 0,
        scrolledUnderElevation: 0,
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
        child: Column(
          children: [
            _buildLoginPrompt(context),
            const SizedBox(height: 32),
            _buildLockedFeatureList(),
          ],
        ),
      ),
    );
  }

  Widget _buildLoginPrompt(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(vertical: 36, horizontal: 24),
      decoration: BoxDecoration(
        color: kSurface,
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
          // 일러스트 아이콘
          Container(
            width: 80,
            height: 80,
            decoration: BoxDecoration(
              color: kPrimaryLight,
              shape: BoxShape.circle,
            ),
            child: const Icon(Icons.person_outline_rounded, size: 44, color: kPrimary),
          ),
          const SizedBox(height: 20),

          // 타이틀
          const Text(
            '로그인이 필요해요',
            style: TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.w800,
              color: kTextDark,
              letterSpacing: -0.5,
            ),
          ),
          const SizedBox(height: 8),
          const Text(
            '관심 매물 저장, 맞춤 알림, 검색 기록\n모두 로그인 후 이용 가능합니다.',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 13.5,
              color: kTextMuted,
              height: 1.6,
            ),
          ),
          const SizedBox(height: 28),

          // CTA 버튼
          SizedBox(
            width: double.infinity,
            child: ElevatedButton.icon(
              onPressed: () => _navigateToLogin(context),
              icon: const Icon(Icons.login_rounded, size: 18),
              label: const Text('로그인하고 더 많은 정보 보기'),
            ),
          ),
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton(
              onPressed: () => _navigateToLogin(context),
              child: const Text('이메일로 회원가입'),
            ),
          ),
        ],
      ),
    );
  }

  /// 잠긴 기능 미리보기 목록.
  ///
  /// [PM] 로그인하면 사용할 수 있는 기능을 미리 보여줌으로써
  /// 가입 동기를 부여합니다.
  Widget _buildLockedFeatureList() {
    const features = [
      (icon: Icons.favorite_rounded, color: Color(0xFFE53935), title: '관심 매물 저장', desc: '마음에 드는 매물을 저장하고 비교하세요'),
      (icon: Icons.notifications_active_rounded, color: Color(0xFFFF6F00), title: '맞춤 가격 알림', desc: '원하는 가격대에 매물이 나오면 알려드려요'),
      (icon: Icons.history_rounded, color: Color(0xFF1565C0), title: '검색 기록 저장', desc: '자주 찾는 지역을 빠르게 다시 검색하세요'),
      (icon: Icons.compare_arrows_rounded, color: Color(0xFF2E7D32), title: '매물 비교하기', desc: '여러 매물을 나란히 놓고 비교해보세요'),
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          '로그인하면 이런 기능을 사용할 수 있어요',
          style: TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w600,
            color: kTextMuted,
          ),
        ),
        const SizedBox(height: 12),
        Container(
          decoration: BoxDecoration(
            color: kSurface,
            borderRadius: BorderRadius.circular(16),
            boxShadow: const [
              BoxShadow(
                color: Color(0x0F000000),
                blurRadius: 16,
                offset: Offset(0, 4),
              ),
            ],
          ),
          child: Column(
            children: features.asMap().entries.map((entry) {
              final i = entry.key;
              final f = entry.value;
              return Column(
                children: [
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                    child: Row(
                      children: [
                        Container(
                          width: 42,
                          height: 42,
                          decoration: BoxDecoration(
                            color: f.color.withValues(alpha: 0.10),
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Icon(f.icon, color: f.color, size: 22),
                        ),
                        const SizedBox(width: 14),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                f.title,
                                style: const TextStyle(
                                  fontSize: 14,
                                  fontWeight: FontWeight.w600,
                                  color: kTextDark,
                                ),
                              ),
                              const SizedBox(height: 2),
                              Text(
                                f.desc,
                                style: const TextStyle(fontSize: 12, color: kTextMuted),
                              ),
                            ],
                          ),
                        ),
                        Icon(Icons.lock_outline_rounded, size: 16, color: kTextMuted),
                      ],
                    ),
                  ),
                  if (i < features.length - 1)
                    Divider(height: 1, thickness: 1, color: kBorderColor),
                ],
              );
            }).toList(),
          ),
        ),
      ],
    );
  }

  void _navigateToLogin(BuildContext context) {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const LoginScreen()),
    );
  }
}

// ── 로그인 뷰 ──────────────────────────────────────────────────────────────────

/// 로그인 상태 UI.
///
/// [UX] 환영 메시지와 함께 개인화된 메뉴 목록을 제공합니다.
class _ProfileView extends StatefulWidget {
  const _ProfileView({required this.user});

  final User user;

  @override
  State<_ProfileView> createState() => _ProfileViewState();
}

class _ProfileViewState extends State<_ProfileView> {
  final _authService = AuthService();
  bool _isSigningOut = false;
  String? _originalPhotoUrl;

  @override
  void initState() {
    super.initState();
    _loadOriginalPhotoUrl();
  }

  Future<void> _loadOriginalPhotoUrl() async {
    final uid = widget.user.uid;
    try {
      final doc = await FirebaseFirestore.instance
          .collection('users')
          .doc(uid)
          .get();
      if (doc.exists && mounted) {
        setState(
            () => _originalPhotoUrl = doc.data()?['originalPhotoUrl'] as String?);
      }
    } catch (_) {}
  }

  Future<void> _confirmSignOut() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('로그아웃'),
        content: const Text(
          '로그아웃하시겠습니까?',
          style: TextStyle(fontSize: 14, height: 1.5),
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
            style: ElevatedButton.styleFrom(minimumSize: const Size(88, 44)),
            child: const Text('로그아웃'),
          ),
        ],
      ),
    );

    if (confirmed != true || !mounted) return;

    setState(() => _isSigningOut = true);
    try {
      await _authService.signOut();
      // authStateChanges Stream이 null을 emit하면 StreamBuilder가 _GuestView로 전환
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('로그아웃 실패: ${e.toString().replaceAll("Exception: ", "")}'),
          backgroundColor: Colors.red.shade700,
          margin: const EdgeInsets.all(16),
        ),
      );
      setState(() => _isSigningOut = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    // email은 프로필 수정으로 바뀌지 않으므로 widget.user에서 한 번만 읽습니다.
    final email = widget.user.email ?? '사용자';

    return Scaffold(
      backgroundColor: kBackground,
      appBar: AppBar(
        title: const Text('내 정보'),
        backgroundColor: kSurface,
        elevation: 0,
        scrolledUnderElevation: 0,
        actions: [
          IconButton(
            icon: const Icon(Icons.settings_outlined),
            tooltip: '설정',
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const SettingsScreen()),
            ),
          ),
        ],
      ),
      body: SingleChildScrollView(
        child: Column(
          children: [
            // 프로필 헤더
            _buildProfileHeader(email),
            const SizedBox(height: 20),

            // 퀵 통계
            _buildQuickStats(),
            const SizedBox(height: 20),

            // 메뉴 목록
            _buildMenuSection(),
            const SizedBox(height: 24),

            // 로그아웃 버튼
            _buildSignOutButton(),
            const SizedBox(height: 32),
          ],
        ),
      ),
    );
  }

  /// 프로필 헤더 (아바타 + 이름 + 이메일 + 편집 버튼) — 흰색 배경 iOS 스타일.
  ///
  /// [반응형] 내부 StreamBuilder가 FirebaseAuth.instance.userChanges()를 구독합니다.
  /// EditProfileScreen에서 프로필 사진·닉네임이 변경되어 reload()가 호출되면
  /// userChanges()가 새 User를 emit하고, setState 없이 이 위젯만 자동 리렌더링됩니다.
  Widget _buildProfileHeader(String email) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(20, 24, 20, 24),
      decoration: const BoxDecoration(
        color: kSurface,
      ),
      child: SafeArea(
        top: false,
        bottom: false,
        // [핵심] userChanges() 스트림 → 프로필 변경 시 즉시 리렌더링
        child: StreamBuilder<User?>(
          stream: FirebaseAuth.instance.userChanges(),
          builder: (context, snapshot) {
            final liveUser = snapshot.data;
            final displayName =
                liveUser?.displayName ?? email.split('@').first;
            final initial =
                displayName.isNotEmpty ? displayName[0].toUpperCase() : '?';
            final photoURL = liveUser?.photoURL;

            return Row(
              children: [
                // 아바타: CachedNetworkImage + 탭 시 팝업 뷰어
                GestureDetector(
                  onTap: _originalPhotoUrl != null
                      ? () => showImageViewerDialog(context, _originalPhotoUrl!)
                      : null,
                  child: Container(
                    width: 64,
                    height: 64,
                    decoration: BoxDecoration(
                      color: kPrimaryLight,
                      shape: BoxShape.circle,
                    ),
                    child: ClipOval(
                      child: photoURL != null
                          ? CachedNetworkImage(
                              imageUrl: photoURL,
                              fit: BoxFit.cover,
                              placeholder: (context, url) => const Center(
                                child: CircularProgressIndicator(
                                  color: kPrimary,
                                  strokeWidth: 2,
                                ),
                              ),
                              errorWidget: (context, url, err) => Center(
                                child: Text(
                                  initial,
                                  style: const TextStyle(
                                    color: kPrimary,
                                    fontSize: 26,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                              ),
                            )
                          : Center(
                              child: Text(
                                initial,
                                style: const TextStyle(
                                  color: kPrimary,
                                  fontSize: 26,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ),
                    ),
                  ),
                ),
                const SizedBox(width: 16),

                // 이름 + 이메일
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        displayName,
                        style: const TextStyle(
                          color: kTextDark,
                          fontSize: 18,
                          fontWeight: FontWeight.w700,
                          letterSpacing: -0.4,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        email,
                        style: const TextStyle(
                          color: kTextMuted,
                          fontSize: 13,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),

                // 프로필 편집 버튼 → EditProfileScreen push
                GestureDetector(
                  onTap: () => Navigator.push(
                    context,
                    MaterialPageRoute(
                        builder: (_) => const EditProfileScreen()),
                  ),
                  child: Container(
                    width: 36,
                    height: 36,
                    decoration: BoxDecoration(
                      color: kPrimaryLight,
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(Icons.edit_outlined,
                        color: kPrimary, size: 17),
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _buildQuickStats() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: Container(
        decoration: BoxDecoration(
          color: kSurface,
          borderRadius: BorderRadius.circular(16),
          boxShadow: const [
            BoxShadow(color: Color(0x0F000000), blurRadius: 16, offset: Offset(0, 4)),
          ],
        ),
        padding: const EdgeInsets.symmetric(vertical: 16),
        child: Row(
          children: [
            _StatCell(
              label: '관심 매물',
              stream: FavoriteService().favoriteCountStream(),
              showDivider: true,
              onTap: () => Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const FavoriteListScreen()),
              ),
            ),
            _StatCell(
              label: '최근 본 매물',
              stream: RecentViewService().recentViewCountStream(),
              showDivider: true,
              onTap: () => Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const RecentViewScreen()),
              ),
            ),
            _StatCell(
              label: '임장 노트',
              stream: _imjangCountStream(),
              showDivider: false,
              onTap: () => Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const ImjangScreen()),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Stream<int> _imjangCountStream() {
    final uid = widget.user.uid;
    return FirebaseFirestore.instance
        .collection('imjang_records')
        .where('uid', isEqualTo: uid)
        .snapshots()
        .map((s) => s.size);
  }

  Widget _buildMenuSection() {
    final menus = [
      _MenuGroup(title: '내 활동', items: [
        _MenuItem(
          icon: Icons.favorite_rounded,
          iconColor: const Color(0xFFE53935),
          title: '관심 매물',
          badge: null,
          onTap: () => Navigator.push(
            context,
            MaterialPageRoute(builder: (_) => const FavoriteListScreen()),
          ),
        ),
        _MenuItem(
          icon: Icons.history_rounded,
          iconColor: const Color(0xFF1565C0),
          title: '최근 본 매물',
          badge: null,
          onTap: () => Navigator.push(
            context, MaterialPageRoute(builder: (_) => const RecentViewScreen()),
          ),
        ),
        _MenuItem(
          icon: Icons.notifications_rounded,
          iconColor: const Color(0xFFFF6F00),
          title: '알림 설정',
          badge: null,
          onTap: () => Navigator.push(
            context, MaterialPageRoute(builder: (_) => const SettingsScreen()),
          ),
        ),
      ]),
      _MenuGroup(title: '고객지원', items: [
        _MenuItem(
          icon: Icons.headset_mic_outlined,
          iconColor: const Color(0xFF2E7D32),
          title: '고객센터',
          badge: null,
          onTap: () => Navigator.push(
            context, MaterialPageRoute(builder: (_) => const SettingsScreen()),
          ),
        ),
        _MenuItem(
          icon: Icons.info_outline_rounded,
          iconColor: kTextMuted,
          title: '앱 정보',
          badge: null,
          onTap: () => Navigator.push(
            context, MaterialPageRoute(builder: (_) => const SettingsScreen()),
          ),
        ),
      ]),
    ];

    return Column(
      children: menus.map((group) {
        return Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.only(left: 4, bottom: 8),
                child: Text(
                  group.title,
                  style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    color: kTextMuted,
                    letterSpacing: 0.5,
                  ),
                ),
              ),
              Container(
                decoration: BoxDecoration(
                  color: kSurface,
                  borderRadius: BorderRadius.circular(16),
                  boxShadow: const [
                    BoxShadow(
                      color: Color(0x0F000000),
                      blurRadius: 16,
                      offset: Offset(0, 4),
                    ),
                  ],
                ),
                child: Column(
                  children: group.items.asMap().entries.map((entry) {
                    final i = entry.key;
                    final item = entry.value;
                    return Column(
                      children: [
                        InkWell(
                          onTap: item.onTap,
                          borderRadius: BorderRadius.only(
                            topLeft: Radius.circular(i == 0 ? 16 : 0),
                            topRight: Radius.circular(i == 0 ? 16 : 0),
                            bottomLeft: Radius.circular(i == group.items.length - 1 ? 16 : 0),
                            bottomRight: Radius.circular(i == group.items.length - 1 ? 16 : 0),
                          ),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                            child: Row(
                              children: [
                                Container(
                                  width: 38,
                                  height: 38,
                                  decoration: BoxDecoration(
                                    color: item.iconColor.withValues(alpha: 0.10),
                                    borderRadius: BorderRadius.circular(10),
                                  ),
                                  child: Icon(item.icon, color: item.iconColor, size: 20),
                                ),
                                const SizedBox(width: 14),
                                Expanded(
                                  child: Text(
                                    item.title,
                                    style: const TextStyle(
                                      fontSize: 14.5,
                                      fontWeight: FontWeight.w500,
                                      color: kTextDark,
                                    ),
                                  ),
                                ),
                                if (item.badge != null)
                                  Container(
                                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                                    margin: const EdgeInsets.only(right: 6),
                                    decoration: BoxDecoration(
                                      color: kPrimaryLight,
                                      borderRadius: BorderRadius.circular(10),
                                    ),
                                    child: Text(
                                      item.badge!,
                                      style: const TextStyle(
                                        fontSize: 11,
                                        fontWeight: FontWeight.w700,
                                        color: kPrimary,
                                      ),
                                    ),
                                  ),
                                Icon(Icons.chevron_right_rounded, color: kTextMuted, size: 20),
                              ],
                            ),
                          ),
                        ),
                        if (i < group.items.length - 1)
                          Divider(height: 1, thickness: 1, indent: 68, color: kBorderColor),
                      ],
                    );
                  }).toList(),
                ),
              ),
            ],
          ),
        );
      }).toList(),
    );
  }

  Widget _buildSignOutButton() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: OutlinedButton.icon(
        onPressed: _isSigningOut ? null : _confirmSignOut,
        icon: _isSigningOut
            ? const SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : Icon(Icons.logout_rounded, size: 18, color: Colors.red.shade400),
        label: Text(
          '로그아웃',
          style: TextStyle(color: Colors.red.shade400, fontWeight: FontWeight.w600),
        ),
        style: OutlinedButton.styleFrom(
          side: BorderSide(color: Colors.red.shade200, width: 1.5),
          foregroundColor: Colors.red.shade400,
          minimumSize: const Size(double.infinity, 48),
        ),
      ),
    );
  }
}

// ── 내부 데이터 모델 ────────────────────────────────────────────────────────────

class _MenuGroup {
  final String title;
  final List<_MenuItem> items;
  const _MenuGroup({required this.title, required this.items});
}

class _MenuItem {
  final IconData icon;
  final Color iconColor;
  final String title;
  final String? badge;
  final VoidCallback? onTap;
  const _MenuItem({required this.icon, required this.iconColor, required this.title, required this.badge, this.onTap});
}

/// 퀵 통계 셀 — Firestore 스트림으로 실시간 카운트 표시.
class _StatCell extends StatelessWidget {
  const _StatCell({
    required this.label,
    required this.stream,
    required this.showDivider,
    this.onTap,
  });

  final String label;
  final Stream<int> stream;
  final bool showDivider;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Stack(
        alignment: Alignment.center,
        children: [
          InkWell(
            onTap: onTap,
            borderRadius: BorderRadius.circular(12),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  StreamBuilder<int>(
                    stream: stream,
                    builder: (context, snap) {
                      final count = snap.data ?? 0;
                      return Text(
                        '$count',
                        style: const TextStyle(
                          fontSize: 22,
                          fontWeight: FontWeight.w800,
                          color: kPrimary,
                          letterSpacing: -0.5,
                        ),
                      );
                    },
                  ),
                  const SizedBox(height: 4),
                  Text(label, style: const TextStyle(fontSize: 12, color: kTextMuted)),
                ],
              ),
            ),
          ),
          if (showDivider)
            Positioned(
              right: 0,
              top: 0,
              bottom: 0,
              child: Center(
                child: Container(width: 1, height: 24, color: kBorderColor),
              ),
            ),
        ],
      ),
    );
  }
}
