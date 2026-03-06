import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../main.dart'
    show kPrimary, kPrimaryLight, kSurface, kBackground, kTextDark, kTextMuted, kBorderColor;
import 'main_tab_screen.dart';

/// SharedPreferences에 저장하는 온보딩 완료 키.
const kOnboardingCompleteKey = 'onboarding_complete';

/// 앱 최초 실행 시 표시되는 권한 안내 온보딩 화면.
///
/// [PM] "다짜고짜 시스템 팝업" 방지 패턴.
/// 1단계: 커스텀 UI로 각 권한의 필요성을 사용자에게 먼저 설명합니다.
/// 2단계: 사용자가 "확인하고 시작하기"를 누를 때만 OS 권한 다이얼로그를 호출합니다.
/// 이 방식은 권한 수락률을 크게 높이고 앱스토어 심사 기준에도 부합합니다.
///
/// [CTO] SharedPreferences 플래그(onboarding_complete)로 최초 실행 여부를 관리합니다.
/// 권한 허용/거절 여부와 무관하게 버튼을 한 번 누르면 온보딩 완료로 처리합니다.
/// (OS 수준에서 권한을 차단해도 앱은 정상 동작하며, 필요 시 재요청 로직이 각 기능에 있음)
class PermissionScreen extends StatefulWidget {
  const PermissionScreen({super.key});

  @override
  State<PermissionScreen> createState() => _PermissionScreenState();
}

class _PermissionScreenState extends State<PermissionScreen> {
  bool _isLoading = false;

  // ── 권한 요청 & 라우팅 ──────────────────────────────────────────────────────────

  /// 권한 순차 요청 → SharedPreferences 완료 표시 → MainTabScreen 전환.
  ///
  /// [QA] try/finally 구조로 권한 처리 중 예외가 발생해도
  /// 온보딩 완료 플래그는 반드시 저장되고 메인 화면으로 이동합니다.
  Future<void> _handlePermissions() async {
    if (_isLoading) return;
    setState(() => _isLoading = true);

    try {
      // 1. 위치 권한 (필수) — 네이버 지도 내 위치 표시
      await Permission.locationWhenInUse.request();

      // 2. 카메라 권한 (선택) — 임장 기록 촬영
      await Permission.camera.request();

      // 3. 사진 라이브러리 권한 (선택)
      //    permission_handler가 Android 버전을 자동 감지:
      //    Android 13+: READ_MEDIA_IMAGES, Android <13: READ_EXTERNAL_STORAGE
      await Permission.photos.request();
    } finally {
      // 허용/거절 관계없이 온보딩 완료 처리
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(kOnboardingCompleteKey, true);

      if (mounted) {
        // FadeTransition으로 MainTabScreen으로 부드럽게 전환
        Navigator.pushReplacement(
          context,
          PageRouteBuilder(
            pageBuilder: (context, animation, secondaryAnimation) =>
                const MainTabScreen(),
            transitionsBuilder: (context, animation, secondaryAnimation, child) {
              return FadeTransition(
                opacity: CurvedAnimation(
                  parent: animation,
                  curve: Curves.easeOut,
                ),
                child: child,
              );
            },
            transitionDuration: const Duration(milliseconds: 450),
          ),
        );
      }
    }
  }

  // ── Build ────────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: kBackground,
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _buildHeader(),
            Expanded(child: _buildBody()),
            _buildCTAButton(),
          ],
        ),
      ),
    );
  }

  // ── 상단 그라디언트 헤더 ─────────────────────────────────────────────────────────

  Widget _buildHeader() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(24, 44, 24, 40),
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [kPrimary, kPrimaryLight, Color(0xFF1A4FA0)],
        ),
      ),
      child: Column(
        children: [
          // 앱 아이콘
          Container(
            width: 74,
            height: 74,
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(22),
              border: Border.all(
                color: Colors.white.withValues(alpha: 0.30),
                width: 1.5,
              ),
            ),
            child: const Icon(
              Icons.location_city_rounded,
              size: 42,
              color: Colors.white,
            ),
          ),
          const SizedBox(height: 18),

          // 앱 이름
          const Text(
            '집로그',
            style: TextStyle(
              color: Colors.white,
              fontSize: 26,
              fontWeight: FontWeight.w800,
              letterSpacing: -0.6,
            ),
          ),
          const SizedBox(height: 10),

          // 온보딩 안내 문구
          const Text(
            '집로그를 100% 활용하기 위해\n다음 권한이 필요합니다',
            textAlign: TextAlign.center,
            style: TextStyle(
              color: Colors.white,
              fontSize: 15.5,
              fontWeight: FontWeight.w500,
              height: 1.55,
              letterSpacing: -0.2,
            ),
          ),
        ],
      ),
    );
  }

  // ── 권한 목록 + 안내 ──────────────────────────────────────────────────────────

  Widget _buildBody() {
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(20, 24, 20, 0),
      child: Column(
        children: [
          // 권한 카드
          Container(
            decoration: BoxDecoration(
              color: kSurface,
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: kBorderColor),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.04),
                  blurRadius: 16,
                  offset: const Offset(0, 4),
                ),
              ],
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 18, 20, 0),
                  child: Text(
                    '권한 안내',
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                      color: kTextMuted,
                      letterSpacing: 0.8,
                    ),
                  ),
                ),
                const SizedBox(height: 4),

                // ① 위치 권한 (필수)
                _buildPermissionRow(
                  icon: Icons.location_on_rounded,
                  iconColor: const Color(0xFF1565C0),
                  iconBgColor: const Color(0xFFE8F0FE),
                  label: '위치',
                  badge: '필수',
                  badgeBgColor: const Color(0xFFE8F0FE),
                  badgeTextColor: const Color(0xFF1565C0),
                  description: '내 주변 매물 탐색 및 지도 이동에 사용됩니다',
                  isLast: false,
                ),

                // ② 카메라 / 사진 권한 (선택)
                _buildPermissionRow(
                  icon: Icons.photo_camera_rounded,
                  iconColor: const Color(0xFF2E7D32),
                  iconBgColor: const Color(0xFFE8F5E9),
                  label: '카메라 / 사진',
                  badge: '선택',
                  badgeBgColor: const Color(0xFFF1F8E9),
                  badgeTextColor: const Color(0xFF33691E),
                  description: '임장 기록 사진·동영상 업로드에 사용됩니다',
                  isLast: true,
                ),
              ],
            ),
          ),

          const SizedBox(height: 16),

          // 하단 보조 안내 문구
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 13),
            decoration: BoxDecoration(
              color: kPrimary.withValues(alpha: 0.05),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: kPrimary.withValues(alpha: 0.12)),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Icon(
                  Icons.info_outline_rounded,
                  size: 16,
                  color: kPrimary,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '권한은 언제든지 휴대폰 설정 앱에서 변경할 수 있습니다.\n'
                    '선택 권한을 거절해도 지도 탐색은 정상 이용 가능합니다.',
                    style: TextStyle(
                      fontSize: 12,
                      color: kPrimary.withValues(alpha: 0.75),
                      height: 1.55,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPermissionRow({
    required IconData icon,
    required Color iconColor,
    required Color iconBgColor,
    required String label,
    required String badge,
    required Color badgeBgColor,
    required Color badgeTextColor,
    required String description,
    required bool isLast,
  }) {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 18),
          child: Row(
            children: [
              // 아이콘
              Container(
                width: 50,
                height: 50,
                decoration: BoxDecoration(
                  color: iconBgColor,
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Icon(icon, color: iconColor, size: 26),
              ),
              const SizedBox(width: 14),

              // 텍스트
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Text(
                          label,
                          style: const TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w700,
                            color: kTextDark,
                            letterSpacing: -0.3,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 7,
                            vertical: 2,
                          ),
                          decoration: BoxDecoration(
                            color: badgeBgColor,
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: Text(
                            badge,
                            style: TextStyle(
                              fontSize: 10,
                              fontWeight: FontWeight.w700,
                              color: badgeTextColor,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text(
                      description,
                      style: const TextStyle(
                        fontSize: 12.5,
                        color: kTextMuted,
                        height: 1.4,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        if (!isLast)
          Divider(
            height: 1,
            thickness: 1,
            indent: 20,
            endIndent: 20,
            color: kBorderColor,
          ),
      ],
    );
  }

  // ── CTA 버튼 ─────────────────────────────────────────────────────────────────

  Widget _buildCTAButton() {
    final bottomPadding = MediaQuery.of(context).padding.bottom;

    return Padding(
      padding: EdgeInsets.fromLTRB(20, 16, 20, bottomPadding + 20),
      child: ElevatedButton(
        onPressed: _isLoading ? null : _handlePermissions,
        child: _isLoading
            ? const SizedBox(
                width: 22,
                height: 22,
                child: CircularProgressIndicator(
                  strokeWidth: 2.5,
                  color: Colors.white,
                ),
              )
            : const Text('확인하고 시작하기'),
      ),
    );
  }
}
