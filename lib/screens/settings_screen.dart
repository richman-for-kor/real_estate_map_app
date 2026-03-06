import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

import '../main.dart'
    show kPrimary, kSurface, kBackground, kBorderColor, kTextDark, kTextMuted;

// ─── 앱 상수 ──────────────────────────────────────────────────────────────────
const _kAppVersion = '1.0.0';
const _kSupportEmail = 'support@realestate-insight.com';
const _kPrefPushNotif = 'push_notifications';

/// 설정 화면 — iOS Grouped List 스타일.
///
/// [구성]
///   1. 알림 설정  : 푸시 알림 ON/OFF (SharedPreferences 로컬 저장)
///   2. 고객센터   : 이메일 문의 (url_launcher)
///   3. 앱 정보    : 앱 버전 · 오픈소스 라이선스
///   4. 계정 관리  : 회원 탈퇴 (EditProfileScreen에서 이전)
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  bool _notificationsEnabled = false;
  bool _isDeleting = false;

  @override
  void initState() {
    super.initState();
    _loadPrefs();
  }

  Future<void> _loadPrefs() async {
    final prefs = await SharedPreferences.getInstance();
    if (mounted) {
      setState(
        () => _notificationsEnabled = prefs.getBool(_kPrefPushNotif) ?? false,
      );
    }
  }

  Future<void> _onNotificationToggle(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kPrefPushNotif, value);
    if (mounted) setState(() => _notificationsEnabled = value);
  }

  // ── 이메일 문의 ──────────────────────────────────────────────────────────────

  Future<void> _openEmail() async {
    final uri = Uri(
      scheme: 'mailto',
      path: _kSupportEmail,
      queryParameters: {
        'subject': '[부동산 인사이트] 문의사항',
        'body': '문의 내용을 입력해 주세요.\n\n──────────────\n앱 버전: $_kAppVersion',
      },
    );
    if (!await launchUrl(uri)) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('이메일 앱을 열 수 없습니다.'),
            margin: EdgeInsets.all(16),
          ),
        );
      }
    }
  }

  // ── 회원 탈퇴 ────────────────────────────────────────────────────────────────

  /// 탈퇴 확인 팝업 → `user.delete()` 시도.
  ///
  /// `requires-recent-login` 발생 시 프로바이더에 따라 재인증:
  ///   - 이메일 유저 → 비밀번호 입력 다이얼로그
  ///   - Google 유저 → GoogleSignIn 재인증
  Future<void> _showDeleteAccountDialog() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;

    final confirmed = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: Row(
          children: [
            Icon(Icons.warning_amber_rounded,
                color: Colors.red.shade600, size: 24),
            const SizedBox(width: 8),
            const Text('회원 탈퇴'),
          ],
        ),
        content: const Text(
          '정말로 탈퇴하시겠습니까?\n임장 노트, 관심 매물 등\n모든 데이터가 삭제됩니다.',
          style: TextStyle(fontSize: 14, height: 1.65),
        ),
        actionsPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        actions: [
          OutlinedButton(
            onPressed: () => Navigator.pop(ctx, false),
            style: OutlinedButton.styleFrom(
              minimumSize: const Size(72, 44),
              side: const BorderSide(color: kBorderColor, width: 1.5),
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10)),
            ),
            child: const Text('취소'),
          ),
          const SizedBox(width: 8),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: ElevatedButton.styleFrom(
              minimumSize: const Size(88, 44),
              backgroundColor: Colors.red.shade700,
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10)),
            ),
            child: const Text('탈퇴하기'),
          ),
        ],
      ),
    );

    if (confirmed != true || !mounted) return;

    setState(() => _isDeleting = true);
    try {
      await user.delete();
      if (mounted) Navigator.of(context).popUntil((r) => r.isFirst);
    } on FirebaseAuthException catch (e) {
      if (e.code == 'requires-recent-login') {
        await _handleReauthAndDelete(user);
      } else {
        if (mounted) {
          setState(() => _isDeleting = false);
          _showSnackBar(_parseAuthError(e));
        }
      }
    }
  }

  Future<void> _handleReauthAndDelete(User user) async {
    final isEmail =
        user.providerData.any((p) => p.providerId == 'password');
    if (isEmail) {
      await _emailReauthAndDelete(user);
    } else {
      await _googleReauthAndDelete(user);
    }
  }

  /// 이메일 유저 재인증: 비밀번호 입력 다이얼로그 → reauthenticate → delete.
  Future<void> _emailReauthAndDelete(User user) async {
    final pwCtrl = TextEditingController();
    bool obscure = true;

    final confirmed = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) => AlertDialog(
          title: const Text('본인 확인'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                '탈퇴를 위해 현재 비밀번호를 입력해 주세요.',
                style: TextStyle(fontSize: 13, height: 1.5),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: pwCtrl,
                obscureText: obscure,
                autofocus: true,
                decoration: InputDecoration(
                  labelText: '현재 비밀번호',
                  prefixIcon: const Icon(Icons.lock_outline_rounded),
                  suffixIcon: IconButton(
                    icon: Icon(
                      obscure
                          ? Icons.visibility_off_outlined
                          : Icons.visibility_outlined,
                      size: 20,
                    ),
                    color: Colors.grey.shade400,
                    onPressed: () => setLocal(() => obscure = !obscure),
                  ),
                ),
              ),
            ],
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
                minimumSize: const Size(88, 44),
                backgroundColor: Colors.red.shade700,
                foregroundColor: Colors.white,
              ),
              child: const Text('탈퇴'),
            ),
          ],
        ),
      ),
    );

    if (confirmed != true || !mounted) {
      pwCtrl.dispose();
      if (mounted) setState(() => _isDeleting = false);
      return;
    }

    try {
      final credential = EmailAuthProvider.credential(
        email: user.email!,
        password: pwCtrl.text,
      );
      await user.reauthenticateWithCredential(credential);
      await user.delete();
      if (mounted) Navigator.of(context).popUntil((r) => r.isFirst);
    } on FirebaseAuthException catch (e) {
      if (mounted) {
        setState(() => _isDeleting = false);
        _showSnackBar(_parseAuthError(e));
      }
    } finally {
      pwCtrl.dispose();
    }
  }

  /// Google 유저 재인증: GoogleSignIn 팝업 → reauthenticate → delete.
  Future<void> _googleReauthAndDelete(User user) async {
    try {
      final googleUser = await GoogleSignIn.instance.authenticate();
      final googleAuth = googleUser.authentication;
      final credential = GoogleAuthProvider.credential(
        idToken: googleAuth.idToken,
      );
      await user.reauthenticateWithCredential(credential);
      await user.delete();
      if (mounted) Navigator.of(context).popUntil((r) => r.isFirst);
    } on GoogleSignInException catch (e) {
      if (e.code == GoogleSignInExceptionCode.canceled) {
        if (mounted) setState(() => _isDeleting = false);
        return;
      }
      if (mounted) {
        setState(() => _isDeleting = false);
        _showSnackBar('재인증에 실패했습니다. 다시 시도해 주세요.');
      }
    } catch (_) {
      if (mounted) {
        setState(() => _isDeleting = false);
        _showSnackBar('재인증에 실패했습니다. 다시 시도해 주세요.');
      }
    }
  }

  void _showSnackBar(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), margin: const EdgeInsets.all(16)),
    );
  }

  String _parseAuthError(FirebaseAuthException e) {
    switch (e.code) {
      case 'wrong-password':
      case 'invalid-credential':
        return '비밀번호가 올바르지 않습니다.';
      case 'requires-recent-login':
        return '보안을 위해 재로그인 후 다시 시도해주세요.';
      default:
        return '인증 오류가 발생했습니다. (${e.code})';
    }
  }

  // ── Build ──────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: kBackground,
      appBar: AppBar(title: const Text('설정')),
      body: Stack(
        children: [
          ListView(
            padding: const EdgeInsets.symmetric(vertical: 8),
            children: [
              // ① 알림 설정
              _SectionHeader(title: '알림 설정'),
              _GroupCard(children: [
                _SwitchTile(
                  icon: Icons.notifications_outlined,
                  iconColor: const Color(0xFFFF6F00),
                  title: '푸시 알림',
                  subtitle: '매물 가격 변동 및 관심 매물 알림',
                  value: _notificationsEnabled,
                  onChanged: _onNotificationToggle,
                ),
              ]),

              // ② 고객센터
              _SectionHeader(title: '고객센터'),
              _GroupCard(children: [
                _NavTile(
                  icon: Icons.email_outlined,
                  iconColor: const Color(0xFF1565C0),
                  title: '이메일 문의하기',
                  subtitle: _kSupportEmail,
                  onTap: _openEmail,
                ),
              ]),

              // ③ 앱 정보
              _SectionHeader(title: '앱 정보'),
              _GroupCard(children: [
                _NavTile(
                  icon: Icons.phone_iphone_rounded,
                  iconColor: kPrimary,
                  title: '앱 버전',
                  trailing: Text(
                    _kAppVersion,
                    style: TextStyle(
                      fontSize: 13,
                      color: Colors.grey.shade500,
                    ),
                  ),
                  showChevron: false,
                  onTap: null,
                ),
                const _ItemDivider(),
                _NavTile(
                  icon: Icons.article_outlined,
                  iconColor: const Color(0xFF2E7D32),
                  title: '오픈소스 라이선스',
                  onTap: () => showLicensePage(
                    context: context,
                    applicationName: '부동산 인사이트',
                    applicationVersion: _kAppVersion,
                  ),
                ),
              ]),

              // ④ 계정 관리
              _SectionHeader(title: '계정 관리'),
              _GroupCard(children: [
                _NavTile(
                  icon: Icons.person_remove_outlined,
                  iconColor: Colors.red.shade400,
                  title: '회원 탈퇴',
                  titleColor: Colors.red.shade500,
                  onTap: _isDeleting ? null : _showDeleteAccountDialog,
                ),
              ]),

              const SizedBox(height: 40),
            ],
          ),

          // 탈퇴 처리 중 오버레이
          if (_isDeleting)
            Container(
              color: Colors.black45,
              child: const Center(
                child: CircularProgressIndicator(color: Colors.white),
              ),
            ),
        ],
      ),
    );
  }
}

// ── 내부 서브 위젯 ─────────────────────────────────────────────────────────────

/// 섹션 레이블.
class _SectionHeader extends StatelessWidget {
  const _SectionHeader({required this.title});
  final String title;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 24, 20, 6),
      child: Text(
        title,
        style: const TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w700,
          color: kTextMuted,
          letterSpacing: 0.5,
        ),
      ),
    );
  }
}

/// Grouped List 카드 컨테이너.
class _GroupCard extends StatelessWidget {
  const _GroupCard({required this.children});
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16),
      decoration: BoxDecoration(
        color: kSurface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: kBorderColor),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: children,
      ),
    );
  }
}

/// 아이템 사이 구분선.
class _ItemDivider extends StatelessWidget {
  const _ItemDivider();

  @override
  Widget build(BuildContext context) {
    return Divider(
      height: 1,
      thickness: 1,
      indent: 56,
      endIndent: 0,
      color: kBorderColor.withValues(alpha: 0.7),
    );
  }
}

/// 스위치 토글 행.
class _SwitchTile extends StatelessWidget {
  const _SwitchTile({
    required this.icon,
    required this.iconColor,
    required this.title,
    this.subtitle,
    required this.value,
    required this.onChanged,
  });

  final IconData icon;
  final Color iconColor;
  final String title;
  final String? subtitle;
  final bool value;
  final ValueChanged<bool>? onChanged;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      child: Row(
        children: [
          _IconBox(icon: icon, color: iconColor),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w500,
                    color: kTextDark,
                  ),
                ),
                if (subtitle != null) ...[
                  const SizedBox(height: 2),
                  Text(
                    subtitle!,
                    style: TextStyle(
                      fontSize: 12,
                      color: Colors.grey.shade500,
                    ),
                  ),
                ],
              ],
            ),
          ),
          Switch(
            value: value,
            onChanged: onChanged,
            activeColor: kPrimary,
          ),
        ],
      ),
    );
  }
}

/// 화살표(또는 커스텀 trailing) 탐색 행.
class _NavTile extends StatelessWidget {
  const _NavTile({
    required this.icon,
    required this.iconColor,
    required this.title,
    this.titleColor,
    this.subtitle,
    this.trailing,
    this.showChevron = true,
    required this.onTap,
  });

  final IconData icon;
  final Color iconColor;
  final String title;
  final Color? titleColor;
  final String? subtitle;
  final Widget? trailing;
  final bool showChevron;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(14),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
        child: Row(
          children: [
            _IconBox(icon: icon, color: iconColor),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w500,
                      color: titleColor ?? kTextDark,
                    ),
                  ),
                  if (subtitle != null) ...[
                    const SizedBox(height: 2),
                    Text(
                      subtitle!,
                      style: TextStyle(
                        fontSize: 12,
                        color: Colors.grey.shade500,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            if (trailing != null) trailing!,
            if (showChevron)
              Icon(
                Icons.chevron_right_rounded,
                size: 20,
                color: Colors.grey.shade400,
              ),
          ],
        ),
      ),
    );
  }
}

/// 색상 배경 아이콘 박스.
class _IconBox extends StatelessWidget {
  const _IconBox({required this.icon, required this.color});
  final IconData icon;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 36,
      height: 36,
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Icon(icon, color: color, size: 19),
    );
  }
}
