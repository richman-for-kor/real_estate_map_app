import 'dart:io';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../main.dart'
    show
        kPrimary,
        kSecondary,
        kSurface,
        kBackground,
        kBorderColor,
        kTextDark,
        kTextMuted;
import '../services/image_service.dart';
import '../widgets/image_viewer_popup.dart';

// ── 비밀번호 정책 (login_screen.dart와 동일 기준) ─────────────────────────────────
// 영문·숫자·특수문자 각 1개 이상 포함, 8~16자
final RegExp _kPasswordRegex = RegExp(
  r'^(?=.*[A-Za-z])(?=.*\d)(?=.*[!@#$%^&*()\-_=+\[\]{}|;:,.<>?/~`]).{8,16}$',
);

/// 프로필 수정 화면.
///
/// [보안 아키텍처]
/// - 이메일 유저: 진입 시 비밀번호 재확인(Re-authentication) → 폼 진입
/// - Google 유저: 재확인 생략, 바로 폼 진입
///
/// [Firebase 연동]
/// - 이미지: Storage `users/{uid}/profile.jpg` 업로드 → getDownloadURL → updatePhotoURL
/// - 닉네임: updateDisplayName()
/// - 비밀번호: updatePassword() (이메일 유저 전용)
/// - 탈퇴:    currentUser.delete() → MainTabScreen으로 스택 복귀
class EditProfileScreen extends StatefulWidget {
  const EditProfileScreen({super.key});

  @override
  State<EditProfileScreen> createState() => _EditProfileScreenState();
}

class _EditProfileScreenState extends State<EditProfileScreen> {
  // ── Form Keys ─────────────────────────────────────────────────────────────
  final _reauthFormKey = GlobalKey<FormState>();
  final _profileFormKey = GlobalKey<FormState>();

  // ── Controllers ───────────────────────────────────────────────────────────
  final _reauthPasswordCtrl = TextEditingController();
  final _displayNameCtrl = TextEditingController();
  final _newPasswordCtrl = TextEditingController();
  final _confirmPasswordCtrl = TextEditingController();

  // ── UI 상태 ───────────────────────────────────────────────────────────────
  bool _isEmailProvider = false; // 이메일/비밀번호 프로바이더 여부
  bool _isReauthDone = false;    // 재인증 완료 여부
  bool _isLoading = false;
  bool _obscureReauth = true;
  bool _obscureNew = true;
  bool _obscureConfirm = true;

  // ── 이미지 ────────────────────────────────────────────────────────────────
  XFile? _pickedImage;          // 갤러리에서 선택한 이미지 (저장 전)
  String? _originalPhotoUrl;   // Firestore에서 로드한 원본 URL (뷰어 팝업용)

  // ── Services ──────────────────────────────────────────────────────────────
  final _auth = FirebaseAuth.instance;
  final _picker = ImagePicker();

  User? get _user => _auth.currentUser;

  // ── Lifecycle ─────────────────────────────────────────────────────────────

  @override
  void initState() {
    super.initState();
    _initState();
  }

  void _initState() {
    final user = _user;
    if (user == null) return;

    _displayNameCtrl.text = user.displayName ?? '';

    // 로그인 프로바이더 확인
    _isEmailProvider =
        user.providerData.any((p) => p.providerId == 'password');

    // Google 유저는 재인증 없이 바로 편집 폼 진입
    if (!_isEmailProvider) _isReauthDone = true;

    // Firestore에서 원본 이미지 URL 로드 (뷰어 팝업용)
    _loadOriginalPhotoUrl();
  }

  /// Firestore `users/{uid}.originalPhotoUrl` 필드를 읽어 뷰어 팝업에 사용합니다.
  Future<void> _loadOriginalPhotoUrl() async {
    final uid = _user?.uid;
    if (uid == null) return;
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

  @override
  void dispose() {
    _reauthPasswordCtrl.dispose();
    _displayNameCtrl.dispose();
    _newPasswordCtrl.dispose();
    _confirmPasswordCtrl.dispose();
    super.dispose();
  }

  // ── Actions ───────────────────────────────────────────────────────────────

  /// 이메일 유저 재인증.
  ///
  /// [보안] 중요 정보 변경 전 현재 비밀번호로 신원을 재확인합니다.
  /// Firebase `reauthenticateWithCredential`로 서버 측 검증합니다.
  Future<void> _reauthenticate() async {
    if (!_reauthFormKey.currentState!.validate()) return;

    setState(() => _isLoading = true);
    try {
      final credential = EmailAuthProvider.credential(
        email: _user!.email!,
        password: _reauthPasswordCtrl.text,
      );
      await _user!.reauthenticateWithCredential(credential);
      if (mounted) setState(() => _isReauthDone = true);
    } on FirebaseAuthException catch (e) {
      _showSnackBar(_parseAuthError(e));
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  /// 갤러리에서 이미지 선택.
  Future<void> _pickImage() async {
    final image = await _picker.pickImage(
      source: ImageSource.gallery,
      imageQuality: 80,
      maxWidth: 512,
    );
    if (image != null && mounted) setState(() => _pickedImage = image);
  }

  /// 선택한 이미지를 [ImageService]로 압축·업로드합니다.
  ///
  /// [파이프라인]
  /// - 원본(1080px/q80) → Firestore `users/{uid}.originalPhotoUrl` (뷰어 팝업)
  /// - 썸네일(200px/q60) → Auth.photoURL (헤더·목록 렌더링 최적화)
  Future<ImageUploadResult?> _uploadAndSaveImages(String uid) async {
    if (_pickedImage == null) return null;
    return ImageService.uploadProfileImages(File(_pickedImage!.path), uid);
  }

  /// 프로필 저장 (이미지 + 닉네임 + 비밀번호).
  ///
  /// [순서] 이미지 업로드 → displayName → password 순으로 처리합니다.
  /// 각 항목은 변경이 있을 때만 Firebase를 호출하여 불필요한 요청을 줄입니다.
  Future<void> _saveProfile() async {
    if (!_profileFormKey.currentState!.validate()) return;

    setState(() => _isLoading = true);
    try {
      final user = _user!;
      bool anyChange = false;

      // 1. 프로필 이미지 업로드 (압축 → 원본/썸네일 병렬 업로드)
      if (_pickedImage != null) {
        final result = await _uploadAndSaveImages(user.uid);
        if (result != null) {
          // Auth에는 가벼운 썸네일 URL 저장 (헤더·목록 렌더링 최적화)
          await user.updatePhotoURL(result.thumbUrl);
          // Firestore에는 고화질 원본 URL 저장 (이미지 뷰어 팝업용)
          await FirebaseFirestore.instance
              .collection('users')
              .doc(user.uid)
              .set({'originalPhotoUrl': result.originalUrl}, SetOptions(merge: true));
          if (mounted) setState(() => _originalPhotoUrl = result.originalUrl);
          // [동기화] 로컬 Auth 캐시를 즉시 갱신 → userChanges() 스트림 emit 유발
          await FirebaseAuth.instance.currentUser?.reload();
          anyChange = true;
        }
      }

      // 2. 닉네임 변경
      final newName = _displayNameCtrl.text.trim();
      if (newName.isNotEmpty && newName != (user.displayName ?? '')) {
        await user.updateDisplayName(newName);
        // [동기화] 로컬 Auth 캐시를 즉시 갱신 → userChanges() 스트림 emit 유발
        await FirebaseAuth.instance.currentUser?.reload();
        anyChange = true;
      }

      // 3. 비밀번호 변경 (이메일 유저이며 입력된 경우만)
      final newPw = _newPasswordCtrl.text;
      if (_isEmailProvider && newPw.isNotEmpty) {
        await user.updatePassword(newPw);
        _newPasswordCtrl.clear();
        _confirmPasswordCtrl.clear();
        anyChange = true;
      }

      if (mounted) {
        setState(() => _pickedImage = null);
        _showSnackBar(
          anyChange ? '프로필이 업데이트되었습니다.' : '변경된 내용이 없습니다.',
          isError: false,
        );
      }
    } on FirebaseAuthException catch (e) {
      _showSnackBar(_parseAuthError(e));
    } on FirebaseException catch (e) {
      _showSnackBar('저장 중 오류가 발생했습니다. (${e.code})');
    } catch (_) {
      _showSnackBar('저장 중 알 수 없는 오류가 발생했습니다.');
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  /// 회원 탈퇴 확인 팝업 → 탈퇴 처리.
  ///
  /// [보안] `currentUser.delete()`는 최근 인증이 필요합니다.
  /// 이메일 유저는 이미 `_reauthenticate()`를 통과했으므로 안전합니다.
  Future<void> _showDeleteAccountDialog() async {
    final confirmed = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: Row(
          children: [
            Icon(Icons.warning_amber_rounded, color: Colors.red.shade600, size: 24),
            const SizedBox(width: 8),
            const Text('회원 탈퇴'),
          ],
        ),
        content: const Text(
          '정말로 탈퇴하시겠습니까?\n모든 데이터가 삭제됩니다.',
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

    setState(() => _isLoading = true);
    try {
      await _user!.delete();
      if (mounted) {
        // 모든 스택 제거 후 루트(MainTabScreen) 복귀.
        // MyPageScreen의 authStateChanges가 null을 emit하여 _GuestView로 자동 전환됩니다.
        Navigator.of(context).popUntil((route) => route.isFirst);
      }
    } on FirebaseAuthException catch (e) {
      if (e.code == 'requires-recent-login' && !_isEmailProvider) {
        // Google 유저: 로그인 경과 시간이 길면 requires-recent-login 발생.
        // 팝업 재인증 후 삭제를 재시도합니다.
        final success = await _reauthGoogleAndRetryDelete();
        if (!success && mounted) {
          setState(() => _isLoading = false);
          _showSnackBar('재인증에 실패했습니다. 다시 시도해 주세요.');
        }
      } else {
        if (mounted) {
          setState(() => _isLoading = false);
          _showSnackBar(_parseAuthError(e));
        }
      }
    }
  }

  /// Google 유저 재인증 후 계정 삭제 재시도.
  ///
  /// [흐름] GoogleSignIn.instance.authenticate() 팝업 → idToken 취득
  ///        → reauthenticateWithCredential() → delete() → 루트로 복귀
  /// [v7 호환] accessToken 없이 idToken만 사용 (google_sign_in v7 스펙).
  Future<bool> _reauthGoogleAndRetryDelete() async {
    try {
      // google_sign_in v7 싱글톤 — serverClientId는 main.dart initialize() 완료 상태
      final googleUser = await GoogleSignIn.instance.authenticate();
      final googleAuth = googleUser.authentication;
      final credential = GoogleAuthProvider.credential(
        idToken: googleAuth.idToken,
      );

      await _user!.reauthenticateWithCredential(credential);
      await _user!.delete();

      if (mounted) {
        Navigator.of(context).popUntil((route) => route.isFirst);
      }
      return true;
    } on GoogleSignInException catch (e) {
      // 사용자가 직접 취소한 경우 조용히 실패
      if (e.code == GoogleSignInExceptionCode.canceled) return false;
      debugPrint('[EditProfile] Google 재인증 실패: ${e.description}');
      return false;
    } catch (e) {
      debugPrint('[EditProfile] 계정 삭제 재시도 실패: $e');
      return false;
    }
  }

  // ── Helpers ───────────────────────────────────────────────────────────────

  void _showSnackBar(String msg, {bool isError = true}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(msg),
        backgroundColor:
            isError ? const Color(0xFFD32F2F) : const Color(0xFF1B5E20),
        margin: const EdgeInsets.all(16),
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ),
    );
  }

  String _parseAuthError(FirebaseAuthException e) {
    switch (e.code) {
      case 'wrong-password':
      case 'invalid-credential':
        return '비밀번호가 올바르지 않습니다.';
      case 'requires-recent-login':
        return '보안을 위해 재로그인 후 다시 시도해주세요.';
      case 'weak-password':
        return '비밀번호는 영문, 숫자, 특수문자를 포함하여 8~16자리로 입력해 주세요.';
      case 'user-not-found':
        return '사용자 정보를 찾을 수 없습니다.';
      default:
        return '인증 오류가 발생했습니다. (${e.code})';
    }
  }

  // ── Build ──────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: kBackground,
      appBar: AppBar(title: const Text('프로필 편집')),
      body: Stack(
        children: [
          // 본인 확인 완료 여부에 따라 뷰 전환 (AnimatedSwitcher로 부드럽게)
          AnimatedSwitcher(
            duration: const Duration(milliseconds: 320),
            switchInCurve: Curves.easeOut,
            switchOutCurve: Curves.easeIn,
            child: _isReauthDone ? _buildProfileForm() : _buildReauthView(),
          ),
          // 전역 로딩 오버레이
          if (_isLoading)
            Container(
              color: Colors.black.withOpacity(0.35),
              child: const Center(
                child: CircularProgressIndicator(color: kSurface),
              ),
            ),
        ],
      ),
    );
  }

  // ── Re-auth View ───────────────────────────────────────────────────────────

  /// 본인 확인 뷰 (이메일 유저 전용).
  ///
  /// [UX] 화면 전체를 잠그고 비밀번호 입력을 요구하여
  /// 무단 정보 변경을 방지합니다. (뱅킹 앱 수준의 보안 UX)
  Widget _buildReauthView() {
    return Center(
      key: const ValueKey('reauth'),
      child: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 48),
        child: Form(
          key: _reauthFormKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // 잠금 아이콘
              Container(
                width: 84,
                height: 84,
                decoration: BoxDecoration(
                  color: kPrimary.withOpacity(0.08),
                  shape: BoxShape.circle,
                ),
                child: const Icon(
                  Icons.lock_person_rounded,
                  size: 40,
                  color: kPrimary,
                ),
              ),
              const SizedBox(height: 24),
              const Text(
                '본인 확인',
                style: TextStyle(
                  fontSize: 22,
                  fontWeight: FontWeight.w800,
                  color: kTextDark,
                  letterSpacing: -0.5,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                '개인정보 보호를 위해\n현재 비밀번호를 입력해 주세요.',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 14,
                  color: Colors.grey.shade500,
                  height: 1.6,
                ),
              ),
              const SizedBox(height: 32),

              // 이메일 (읽기 전용 표시)
              Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 15),
                decoration: BoxDecoration(
                  color: Colors.grey.shade100,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: kBorderColor),
                ),
                child: Text(
                  _user?.email ?? '',
                  style: const TextStyle(fontSize: 14, color: kTextMuted),
                ),
              ),
              const SizedBox(height: 12),

              // 비밀번호 입력
              TextFormField(
                controller: _reauthPasswordCtrl,
                obscureText: _obscureReauth,
                textInputAction: TextInputAction.done,
                onFieldSubmitted: (_) => _reauthenticate(),
                decoration: InputDecoration(
                  labelText: '현재 비밀번호',
                  hintText: '비밀번호를 입력하세요',
                  prefixIcon: const Icon(Icons.lock_outline_rounded),
                  suffixIcon: IconButton(
                    icon: Icon(
                      _obscureReauth
                          ? Icons.visibility_off_outlined
                          : Icons.visibility_outlined,
                      size: 20,
                    ),
                    color: Colors.grey.shade400,
                    onPressed: () =>
                        setState(() => _obscureReauth = !_obscureReauth),
                  ),
                ),
                validator: (v) {
                  if (v == null || v.isEmpty) return '비밀번호를 입력해주세요.';
                  return null;
                },
              ),
              const SizedBox(height: 24),

              // 확인 버튼
              ElevatedButton(
                onPressed: _isLoading ? null : _reauthenticate,
                child: const Text('확인'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ── Profile Form ───────────────────────────────────────────────────────────

  Widget _buildProfileForm() {
    return Form(
      key: _profileFormKey,
      child: ListView(
        key: const ValueKey('profile'),
        padding: const EdgeInsets.fromLTRB(20, 32, 20, 48),
        children: [
          // 프로필 이미지
          _buildAvatarSection(),
          const SizedBox(height: 32),

          // 기본 정보 카드
          _buildSectionCard(
            title: '기본 정보',
            children: [_buildDisplayNameField()],
          ),

          // 비밀번호 변경 카드 (이메일 유저 전용)
          if (_isEmailProvider) ...[
            const SizedBox(height: 16),
            _buildSectionCard(
              title: '비밀번호 변경',
              subtitle: '변경하지 않으려면 비워두세요.',
              children: [
                _buildNewPasswordField(),
                const SizedBox(height: 12),
                _buildConfirmPasswordField(),
              ],
            ),
          ],

          const SizedBox(height: 32),

          // 저장 버튼
          ElevatedButton(
            onPressed: _isLoading ? null : _saveProfile,
            child: const Text('저장하기'),
          ),

          // ── 회원 탈퇴 (눈에 잘 안 띄게) ──────────────────────────────────────
          // [PM/UX] 탈퇴는 의도치 않게 누르기 어렵도록 화면 최하단, 작은 글씨로 배치합니다.
          const SizedBox(height: 56),
          Center(
            child: TextButton(
              onPressed: _isLoading ? null : _showDeleteAccountDialog,
              style: TextButton.styleFrom(
                foregroundColor: Colors.grey.shade400,
                minimumSize: Size.zero,
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                textStyle: const TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w400,
                  decoration: TextDecoration.underline,
                ),
              ),
              child: const Text('회원 탈퇴'),
            ),
          ),
          const SizedBox(height: 16),
        ],
      ),
    );
  }

  // ── Widget Builders ────────────────────────────────────────────────────────

  /// 프로필 이미지 + 카메라 아이콘 오버레이.
  ///
  /// [이미지 우선순위] 로컬 선택 > Firestore 원본(뷰어) > Firebase Auth 썸네일 > 이니셜
  /// [탭 동작] 저장된 이미지가 있을 때 아바타 탭 → 팝업 뷰어(핀치 줌)
  Widget _buildAvatarSection() {
    final user = _auth.currentUser;
    final networkUrl = _originalPhotoUrl ?? user?.photoURL;

    Widget avatarContent;
    if (_pickedImage != null) {
      // 갤러리에서 새로 선택한 이미지 (아직 저장 전 → FileImage로 즉시 미리보기)
      avatarContent = Image.file(
        File(_pickedImage!.path),
        fit: BoxFit.cover,
      );
    } else if (networkUrl != null) {
      // 저장된 이미지: CachedNetworkImage + 탭 시 팝업 뷰어
      avatarContent = GestureDetector(
        onTap: () => showImageViewerDialog(context, networkUrl),
        child: CachedNetworkImage(
          imageUrl: networkUrl,
          fit: BoxFit.cover,
          placeholder: (_, __) => const Center(
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
          errorWidget: (_, __, ___) => _buildInitialText(user),
        ),
      );
    } else {
      avatarContent = _buildInitialText(user);
    }

    return Center(
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Container(
            width: 112,
            height: 112,
            decoration: BoxDecoration(
              color: kPrimary.withOpacity(0.10),
              shape: BoxShape.circle,
              border: Border.all(color: kBorderColor, width: 1.5),
            ),
            child: ClipOval(child: avatarContent),
          ),
          // 카메라 아이콘 버튼
          Positioned(
            right: -2,
            bottom: -2,
            child: GestureDetector(
              onTap: _pickImage,
              child: Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  color: kSecondary,
                  shape: BoxShape.circle,
                  border: Border.all(color: kSurface, width: 2.5),
                  boxShadow: [
                    BoxShadow(
                      color: kSecondary.withOpacity(0.30),
                      blurRadius: 8,
                      offset: const Offset(0, 2),
                    ),
                  ],
                ),
                child: const Icon(
                  Icons.camera_alt_rounded,
                  size: 17,
                  color: kSurface,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// 이니셜 텍스트 아바타 (이미지가 없을 때 대체 위젯).
  Widget _buildInitialText(User? user) {
    final name = user?.displayName ?? '';
    final email = user?.email ?? '';
    final initial = name.isNotEmpty
        ? name[0].toUpperCase()
        : email.isNotEmpty
            ? email[0].toUpperCase()
            : '?';
    return Center(
      child: Text(
        initial,
        style: const TextStyle(
          fontSize: 42,
          fontWeight: FontWeight.w700,
          color: kPrimary,
        ),
      ),
    );
  }

  /// 섹션 카드 (기본 정보, 비밀번호 변경 등 공통 컨테이너).
  Widget _buildSectionCard({
    required String title,
    String? subtitle,
    required List<Widget> children,
  }) {
    return Container(
      decoration: BoxDecoration(
        color: kSurface,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: kPrimary.withOpacity(0.05),
            blurRadius: 16,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: const TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w700,
              color: kTextMuted,
              letterSpacing: 0.6,
            ),
          ),
          if (subtitle != null) ...[
            const SizedBox(height: 2),
            Text(
              subtitle,
              style: TextStyle(fontSize: 11, color: Colors.grey.shade400),
            ),
          ],
          const SizedBox(height: 16),
          ...children,
        ],
      ),
    );
  }

  Widget _buildDisplayNameField() {
    return TextFormField(
      controller: _displayNameCtrl,
      textInputAction: TextInputAction.done,
      decoration: const InputDecoration(
        labelText: '닉네임',
        hintText: '표시될 이름을 입력하세요',
        prefixIcon: Icon(Icons.person_outline_rounded),
      ),
      validator: (v) {
        if (v == null || v.trim().isEmpty) return '닉네임을 입력해주세요.';
        if (v.trim().length < 2) return '닉네임은 2자 이상이어야 합니다.';
        return null;
      },
    );
  }

  Widget _buildNewPasswordField() {
    return TextFormField(
      controller: _newPasswordCtrl,
      obscureText: _obscureNew,
      textInputAction: TextInputAction.next,
      decoration: InputDecoration(
        labelText: '새 비밀번호',
        hintText: '영문·숫자·특수문자 포함 8~16자',
        prefixIcon: const Icon(Icons.lock_outline_rounded),
        suffixIcon: IconButton(
          icon: Icon(
            _obscureNew
                ? Icons.visibility_off_outlined
                : Icons.visibility_outlined,
            size: 20,
          ),
          color: Colors.grey.shade400,
          onPressed: () => setState(() => _obscureNew = !_obscureNew),
        ),
      ),
      validator: (v) {
        if (v == null || v.isEmpty) return null; // 비워두면 비밀번호 변경 생략
        if (!_kPasswordRegex.hasMatch(v)) {
          return '비밀번호는 영문, 숫자, 특수문자를 포함하여 8~16자리로 입력해 주세요.';
        }
        return null;
      },
    );
  }

  Widget _buildConfirmPasswordField() {
    return TextFormField(
      controller: _confirmPasswordCtrl,
      obscureText: _obscureConfirm,
      textInputAction: TextInputAction.done,
      onFieldSubmitted: (_) => _saveProfile(),
      decoration: InputDecoration(
        labelText: '새 비밀번호 확인',
        hintText: '새 비밀번호를 다시 입력하세요',
        prefixIcon: const Icon(Icons.lock_outline_rounded),
        suffixIcon: IconButton(
          icon: Icon(
            _obscureConfirm
                ? Icons.visibility_off_outlined
                : Icons.visibility_outlined,
            size: 20,
          ),
          color: Colors.grey.shade400,
          onPressed: () => setState(() => _obscureConfirm = !_obscureConfirm),
        ),
      ),
      validator: (v) {
        final newPw = _newPasswordCtrl.text;
        if (newPw.isEmpty) return null; // 새 비밀번호 미입력 시 건너뜀
        if (v == null || v.isEmpty) return '새 비밀번호 확인을 입력해주세요.';
        if (v != newPw) return '비밀번호가 일치하지 않습니다.';
        return null;
      },
    );
  }
}
