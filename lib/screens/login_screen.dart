import 'package:flutter/material.dart';
import '../main.dart' show kPrimary, kSecondary, kTextDark, kTextMuted, kBorderColor, kSurface;
import '../services/auth_service.dart';

// ── 로그인 화면 전용 색상 ──────────────────────────────────────────────────────────
const Color _kPageBg   = Color(0xFFF7F8FA); // 아주 연한 오프화이트 배경
const Color _kFieldBg  = Color(0xFFF2F3F5); // 텍스트 필드 채우기 색상

// ── 비밀번호 정책 ──────────────────────────────────────────────────────────────────
// 영문(대소문자), 숫자, 특수문자 각 1개 이상 포함 + 8~16자
final RegExp _kPasswordRegex = RegExp(
  r'^(?=.*[A-Za-z])(?=.*\d)(?=.*[!@#$%^&*()\-_=+\[\]{}|;:,.<>?/~`]).{8,16}$',
);

// ── 개인정보 수집 및 이용 약관 텍스트 ─────────────────────────────────────────────
const String _kPrivacyPolicyText = '''
제1조 (개인정보의 수집 및 이용 목적)
집로그(이하 "회사")는 다음의 목적을 위하여 개인정보를 처리합니다.

1. 회원 가입 및 관리
   - 회원 가입 의사 확인, 회원제 서비스 제공에 따른 본인 식별·인증
   - 회원자격 유지·관리, 서비스 부정이용 방지, 각종 고지·통지

2. 서비스 제공
   - 부동산 정보 조회 및 임장 기록 서비스 제공
   - 콘텐츠 제공, 개인 맞춤형 서비스 제공

제2조 (수집하는 개인정보의 항목)
회사는 다음의 개인정보 항목을 처리합니다.

1. 필수 항목: 이메일 주소, 비밀번호
2. 선택 항목: 프로필 사진, 닉네임
3. 자동 수집 항목: 서비스 이용 기록, 접속 로그, 기기 정보

제3조 (개인정보의 처리 및 보유 기간)
1. 회사는 법령에 따른 개인정보 보유·이용 기간 또는 정보주체로부터 개인정보를 수집 시에 동의받은 개인정보 보유·이용 기간 내에서 개인정보를 처리·보유합니다.

2. 각각의 개인정보 처리 및 보유 기간은 다음과 같습니다.
   - 회원 가입 및 관리: 서비스 탈퇴 시까지
   - 관계 법령 위반에 따른 수사·조사가 진행 중인 경우: 해당 수사·조사 종료 시까지

제4조 (개인정보의 제3자 제공)
회사는 정보주체의 개인정보를 제1조에서 명시한 범위 내에서만 처리하며, 정보주체의 동의 또는 법률의 특별한 규정 등에 해당하는 경우에만 개인정보를 제3자에게 제공합니다. 현재 회사는 개인정보를 제3자에게 제공하고 있지 않습니다.

제5조 (정보주체의 권리·의무 및 행사방법)
1. 정보주체는 회사에 대해 언제든지 개인정보 열람·정정·삭제·처리정지 요구 등의 권리를 행사할 수 있습니다.

2. 권리 행사는 이메일을 통하여 하실 수 있으며, 회사는 이에 대해 지체 없이 조치하겠습니다.

제6조 (개인정보의 파기)
회사는 개인정보 보유기간의 경과, 처리목적 달성 등 개인정보가 불필요하게 되었을 때에는 지체없이 해당 개인정보를 파기합니다. 전자적 파일 형태로 저장된 개인정보는 기록을 재생할 수 없는 기술적 방법을 사용하여 삭제합니다.

제7조 (개인정보 보호책임자)
회사는 개인정보 처리에 관한 업무를 총괄하여 책임지고, 정보주체의 개인정보 관련 불만 처리 및 피해구제를 위하여 아래와 같이 개인정보 보호책임자를 지정하고 있습니다.
   - 담당 부서: 집로그 개인정보 보호팀
   - 문의 이메일: privacy@jilog.app

제8조 (개인정보의 안전성 확보 조치)
회사는 개인정보의 안전성 확보를 위해 다음과 같은 조치를 취하고 있습니다.
   1. 관리적 조치: 내부관리계획 수립·시행, 정기적 직원 교육
   2. 기술적 조치: 접근권한 관리, 고유식별정보 암호화, 보안프로그램 설치
   3. 물리적 조치: 전산실 및 자료보관실 접근 통제

이 개인정보 처리방침은 2025년 1월 1일부터 적용됩니다.
''';


/// 로그인 / 회원가입 통합 화면.
///
/// [PM] 별도 라우트 없이 하나의 화면에서 두 모드를 `AnimatedSize`로 전환합니다.
/// [CTO] 로그인/가입 성공 후 화면 전환은 main.dart StreamBuilder가 담당하므로
/// 이 위젯은 Navigator를 직접 호출하지 않습니다.
class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _formKey = GlobalKey<FormState>();
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  final _confirmPasswordController = TextEditingController();
  final _confirmPasswordFocusNode = FocusNode();
  final _authService = AuthService();

  // ── 상태 ──────────────────────────────────────────────────────────────────────
  bool _isLoginMode = true;    // true = 로그인, false = 회원가입
  bool _termsAgreed = false;
  bool _isEmailLoading = false;
  bool _isGoogleLoading = false;
  bool _obscurePassword = true;
  bool _obscureConfirmPassword = true;

  bool get _isAnyLoading => _isEmailLoading || _isGoogleLoading;

  @override
  void dispose() {
    _emailController.dispose();
    _passwordController.dispose();
    _confirmPasswordController.dispose();
    _confirmPasswordFocusNode.dispose();
    super.dispose();
  }

  // ── Actions ────────────────────────────────────────────────────────────────

  /// 로그인/회원가입 모드 전환.
  ///
  /// 전환 시 폼을 초기화하여 이전 모드의 검증 오류가 남지 않도록 합니다.
  void _toggleMode() {
    _formKey.currentState?.reset();
    setState(() {
      _isLoginMode = !_isLoginMode;
      _termsAgreed = false;
      _passwordController.clear();
      _confirmPasswordController.clear();
    });
  }

  /// 이메일/비밀번호 로그인.
  Future<void> _signInWithEmail() async {
    if (!_formKey.currentState!.validate()) return;

    setState(() => _isEmailLoading = true);
    try {
      await _authService.signInWithEmail(
        _emailController.text.trim(),
        _passwordController.text,
      );
      // 성공: MyPageScreen에서 push된 경우 pop하여 탭으로 복귀.
      // MyPageScreen의 StreamBuilder가 로그인 상태를 감지해 UI를 갱신합니다.
      if (mounted && Navigator.canPop(context)) Navigator.pop(context);
    } catch (e) {
      if (mounted) _showSnackBar(_parseError(e));
    } finally {
      if (mounted) setState(() => _isEmailLoading = false);
    }
  }

  /// 이메일/비밀번호 회원가입.
  ///
  /// [QA] 약관 동의 체크 없이 가입 시도 시 SnackBar로 차단합니다.
  Future<void> _registerWithEmail() async {
    if (!_formKey.currentState!.validate()) return;

    if (!_termsAgreed) {
      _showSnackBar('약관에 동의해 주세요.');
      return;
    }

    setState(() => _isEmailLoading = true);
    try {
      await _authService.registerWithEmail(
        email: _emailController.text.trim(),
        password: _passwordController.text,
        // displayName: 이메일 @ 앞 부분을 기본값으로 사용
        displayName: _emailController.text.trim().split('@').first,
        termsAgreed: true,
      );
      if (mounted && Navigator.canPop(context)) Navigator.pop(context);
    } catch (e) {
      if (mounted) _showSnackBar(_parseError(e));
    } finally {
      if (mounted) setState(() => _isEmailLoading = false);
    }
  }

  /// Google 소셜 로그인/가입.
  ///
  /// Google 로그인 시 약관 동의에 동의한 것으로 간주합니다 (disclaimer 안내문 포함).
  Future<void> _signInWithGoogle() async {
    setState(() => _isGoogleLoading = true);
    try {
      await _authService.signInWithGoogle();
      if (mounted && Navigator.canPop(context)) Navigator.pop(context);
    } catch (e) {
      if (mounted) _showSnackBar(_parseError(e));
    } finally {
      if (mounted) setState(() => _isGoogleLoading = false);
    }
  }

  /// 개인정보 수집 및 이용 동의 인앱 팝업.
  ///
  /// [PM] 외부 브라우저 이탈 없이 앱 내부에서 약관을 읽고 바로 동의할 수 있도록 합니다.
  /// [퍼블리셔] SingleChildScrollView로 긴 텍스트를 스크롤 처리하여 AlertDialog 오버플로를 방지합니다.
  void _showTermsDialog() {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('개인정보 수집 및 이용 동의'),
        content: SizedBox(
          width: double.maxFinite,
          child: SingleChildScrollView(
            child: Text(
              _kPrivacyPolicyText,
              style: const TextStyle(fontSize: 13, height: 1.75, color: kTextDark),
            ),
          ),
        ),
        actionsPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            style: TextButton.styleFrom(
              foregroundColor: kPrimary,
              textStyle: const TextStyle(fontWeight: FontWeight.w600),
            ),
            child: const Text('확인'),
          ),
        ],
      ),
    );
  }

  void _showForgotPasswordDialog() {
    showDialog(
      context: context,
      builder: (_) => _ForgotPasswordDialog(authService: _authService),
    );
  }

  void _showSnackBar(String message, {bool isError = true}) {
    ScaffoldMessenger.of(context).showSnackBar(
      _buildSnackBar(message, isError: isError),
    );
  }

  // ── Build ──────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      resizeToAvoidBottomInset: true,
      body: Stack(
        children: [
          _buildBackground(),
          SafeArea(
            child: Center(
              child: SingleChildScrollView(
                keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
                padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 40),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    _buildLogo(),
                    const SizedBox(height: 40),
                    _buildFormCard(),
                    const SizedBox(height: 20),
                    _buildDivider(),
                    const SizedBox(height: 16),
                    _buildGoogleButton(),
                    const SizedBox(height: 8),
                    // [PM] Google 로그인 약관 동의 안내 문구 — 항상 노출
                    _buildGoogleDisclaimer(),
                    const SizedBox(height: 32),
                    _buildToggleModeRow(),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ── Widget Builders ────────────────────────────────────────────────────────

  Widget _buildBackground() {
    return const ColoredBox(color: _kPageBg);
  }

  Widget _buildLogo() {
    return Column(
      children: [
        Container(
          width: 88,
          height: 88,
          decoration: BoxDecoration(
            color: kPrimary,
            borderRadius: BorderRadius.circular(24),
            boxShadow: [
              BoxShadow(
                color: kPrimary.withOpacity(0.30),
                blurRadius: 24,
                spreadRadius: 2,
                offset: const Offset(0, 10),
              ),
            ],
          ),
          child: const Icon(Icons.location_city_rounded, size: 48, color: kSurface),
        ),
        const SizedBox(height: 22),
        const Text(
          '집로그',
          style: TextStyle(
            fontSize: 28,
            fontWeight: FontWeight.w800,
            color: kTextDark,
            letterSpacing: -0.8,
          ),
        ),
        const SizedBox(height: 6),
        // [PM] 모드에 따라 서브타이틀 변경
        AnimatedSwitcher(
          duration: const Duration(milliseconds: 200),
          child: Text(
            _isLoginMode
                ? '지도 위에 남기는 나만의 부동산 일지'
                : '집로그와 함께 나만의 기록을 시작해보세요',
            key: ValueKey(_isLoginMode),
            style: TextStyle(
              fontSize: 14,
              color: Colors.grey.shade500,
              letterSpacing: 0.1,
            ),
          ),
        ),
      ],
    );
  }

  /// 로그인/회원가입 폼 카드.
  ///
  /// [퍼블리셔] `AnimatedSize`로 모드 전환 시 카드 높이가 부드럽게 변합니다.
  Widget _buildFormCard() {
    return Container(
      decoration: BoxDecoration(
        color: kSurface,
        borderRadius: BorderRadius.circular(24),
        boxShadow: [
          BoxShadow(
            color: kPrimary.withOpacity(0.04),
            blurRadius: 24,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      padding: const EdgeInsets.all(24),
      child: Form(
        key: _formKey,
        child: AnimatedSize(
          duration: const Duration(milliseconds: 280),
          curve: Curves.easeInOut,
          alignment: Alignment.topCenter,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              // 모드 헤더
              _buildModeHeader(),
              const SizedBox(height: 20),

              // 이메일 (공통)
              _buildEmailField(),
              const SizedBox(height: 16),

              // 비밀번호 (공통)
              _buildPasswordField(),

              // ── 로그인 모드 전용 ────────────────────────────────────────────
              if (_isLoginMode) ...[
                const SizedBox(height: 8),
                _buildForgotPasswordButton(),
              ],

              // ── 회원가입 모드 전용 ──────────────────────────────────────────
              if (!_isLoginMode) ...[
                const SizedBox(height: 16),
                _buildConfirmPasswordField(),
                const SizedBox(height: 16),
                // [PM/QA] 약관 동의 체크박스 — 회원가입 모드에서만 노출
                _buildTermsCheckbox(),
              ],

              const SizedBox(height: 24),
              _buildPrimaryButton(),
            ],
          ),
        ),
      ),
    );
  }

  /// 폼 카드 상단 모드 레이블.
  Widget _buildModeHeader() {
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 200),
      transitionBuilder: (child, animation) => FadeTransition(
        opacity: animation,
        child: SlideTransition(
          position: Tween<Offset>(
            begin: const Offset(0, -0.2),
            end: Offset.zero,
          ).animate(animation),
          child: child,
        ),
      ),
      child: Align(
        key: ValueKey(_isLoginMode),
        alignment: Alignment.centerLeft,
        child: Text(
          _isLoginMode ? '로그인' : '회원가입',
          style: const TextStyle(
            fontSize: 18,
            fontWeight: FontWeight.w700,
            color: kTextDark,
            letterSpacing: -0.3,
          ),
        ),
      ),
    );
  }

  /// 로그인 화면 전용 텍스트 필드 데코레이션 (테두리 없는 filled 스타일).
  static InputDecoration _fieldDeco({
    String? labelText,
    String? hintText,
    Widget? prefixIcon,
    Widget? suffixIcon,
  }) {
    return InputDecoration(
      labelText: labelText,
      hintText: hintText,
      prefixIcon: prefixIcon,
      suffixIcon: suffixIcon,
      filled: true,
      fillColor: _kFieldBg,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide.none,
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide.none,
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: kPrimary, width: 1.5),
      ),
      errorBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: Color(0xFFEF5350)),
      ),
      focusedErrorBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: Color(0xFFEF5350), width: 1.5),
      ),
    );
  }

  Widget _buildEmailField() {
    return TextFormField(
      controller: _emailController,
      keyboardType: TextInputType.emailAddress,
      textInputAction: TextInputAction.next,
      enabled: !_isAnyLoading,
      decoration: _fieldDeco(
        labelText: '이메일',
        hintText: 'example@email.com',
        prefixIcon: const Icon(Icons.email_outlined),
      ),
      validator: (value) {
        if (value == null || value.trim().isEmpty) return '이메일을 입력해주세요.';
        if (!RegExp(r'^[\w-.]+@([\w-]+\.)+[\w-]{2,}$').hasMatch(value.trim())) {
          return '올바른 이메일 형식이 아닙니다.';
        }
        return null;
      },
    );
  }

  Widget _buildPasswordField() {
    return TextFormField(
      controller: _passwordController,
      obscureText: _obscurePassword,
      // [퍼블리셔] 모드에 따라 키보드 액션 분기: 로그인=완료, 회원가입=다음(확인 필드로)
      textInputAction: _isLoginMode ? TextInputAction.done : TextInputAction.next,
      enabled: !_isAnyLoading,
      onFieldSubmitted: (_) {
        if (_isLoginMode) {
          _signInWithEmail();
        } else {
          _confirmPasswordFocusNode.requestFocus();
        }
      },
      decoration: _fieldDeco(
        labelText: '비밀번호',
        hintText: '영문·숫자·특수문자 포함 8~16자',
        prefixIcon: const Icon(Icons.lock_outline_rounded),
        suffixIcon: IconButton(
          icon: Icon(
            _obscurePassword ? Icons.visibility_off_outlined : Icons.visibility_outlined,
            size: 20,
          ),
          color: Colors.grey.shade400,
          onPressed: () => setState(() => _obscurePassword = !_obscurePassword),
        ),
      ),
      validator: (value) {
        if (value == null || value.isEmpty) return '비밀번호를 입력해주세요.';
        // [보안] 회원가입 모드에서만 강력한 정책을 적용합니다.
        // 로그인 모드는 기존 비밀번호 그대로 전달하므로 길이 체크만 수행합니다.
        if (!_isLoginMode && !_kPasswordRegex.hasMatch(value)) {
          return '비밀번호는 영문, 숫자, 특수문자를 포함하여 8~16자리로 입력해 주세요.';
        }
        return null;
      },
    );
  }

  Widget _buildConfirmPasswordField() {
    return TextFormField(
      controller: _confirmPasswordController,
      focusNode: _confirmPasswordFocusNode,
      obscureText: _obscureConfirmPassword,
      textInputAction: TextInputAction.done,
      enabled: !_isAnyLoading,
      onFieldSubmitted: (_) => _registerWithEmail(),
      decoration: _fieldDeco(
        labelText: '비밀번호 확인',
        hintText: '비밀번호를 다시 입력하세요',
        prefixIcon: const Icon(Icons.lock_outline_rounded),
        suffixIcon: IconButton(
          icon: Icon(
            _obscureConfirmPassword
                ? Icons.visibility_off_outlined
                : Icons.visibility_outlined,
            size: 20,
          ),
          color: Colors.grey.shade400,
          onPressed: () => setState(() => _obscureConfirmPassword = !_obscureConfirmPassword),
        ),
      ),
      validator: (value) {
        // 회원가입 모드에서만 유효성 검사
        if (!_isLoginMode) {
          if (value == null || value.isEmpty) return '비밀번호 확인을 입력해주세요.';
          if (value != _passwordController.text) return '비밀번호가 일치하지 않습니다.';
        }
        return null;
      },
    );
  }

  /// 개인정보 수집 동의 체크박스.
  ///
  /// [PM/QA] isLoginMode == false일 때만 렌더링됩니다.
  /// RichText로 "개인정보 수집 및 이용" 부분을 링크 스타일로 강조합니다.
  Widget _buildTermsCheckbox() {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        SizedBox(
          width: 22,
          height: 22,
          child: Checkbox(
            value: _termsAgreed,
            activeColor: kPrimary,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
            side: BorderSide(color: Colors.grey.shade300, width: 1.5),
            onChanged: _isAnyLoading
                ? null
                : (val) => setState(() => _termsAgreed = val ?? false),
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: GestureDetector(
            onTap: _isAnyLoading
                ? null
                : () => setState(() => _termsAgreed = !_termsAgreed),
            child: Text.rich(
              TextSpan(
                style: const TextStyle(fontSize: 13, color: kTextMuted, height: 1.4),
                children: [
                  const TextSpan(text: '(필수) '),
                  WidgetSpan(
                    alignment: PlaceholderAlignment.middle,
                    child: GestureDetector(
                      // [PM] 링크 탭 → 인앱 약관 팝업 (외부 브라우저 이탈 없음)
                      onTap: _isAnyLoading ? null : _showTermsDialog,
                      child: Text(
                        '개인정보 수집 및 이용',
                        style: TextStyle(
                          fontSize: 13,
                          color: kSecondary,
                          fontWeight: FontWeight.w600,
                          decoration: TextDecoration.underline,
                          decorationColor: kSecondary,
                          height: 1.4,
                        ),
                      ),
                    ),
                  ),
                  const TextSpan(text: '에 동의합니다.'),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildForgotPasswordButton() {
    return Align(
      alignment: Alignment.centerRight,
      child: TextButton(
        onPressed: _isAnyLoading ? null : _showForgotPasswordDialog,
        style: TextButton.styleFrom(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
          minimumSize: Size.zero,
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          foregroundColor: kSecondary,
          textStyle: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500),
        ),
        child: const Text('비밀번호를 잊으셨나요?'),
      ),
    );
  }

  /// 모드에 따라 텍스트와 액션이 변경되는 주요 CTA 버튼.
  ///
  /// [퍼블리셔] `AnimatedSwitcher`로 버튼 텍스트 전환 시 페이드 효과를 줍니다.
  Widget _buildPrimaryButton() {
    return ElevatedButton(
      onPressed: _isAnyLoading
          ? null
          : (_isLoginMode ? _signInWithEmail : _registerWithEmail),
      child: _isEmailLoading
          ? const SizedBox(
              width: 22,
              height: 22,
              child: CircularProgressIndicator(strokeWidth: 2.5, color: kSurface),
            )
          : AnimatedSwitcher(
              duration: const Duration(milliseconds: 200),
              child: Text(
                _isLoginMode ? '이메일로 로그인' : '회원가입하기',
                key: ValueKey(_isLoginMode),
              ),
            ),
    );
  }

  Widget _buildDivider() {
    return Row(
      children: [
        Expanded(child: Divider(color: Colors.grey.shade200, thickness: 1)),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Text(
            '또는',
            style: TextStyle(
              fontSize: 13,
              color: Colors.grey.shade400,
              fontWeight: FontWeight.w500,
            ),
          ),
        ),
        Expanded(child: Divider(color: Colors.grey.shade200, thickness: 1)),
      ],
    );
  }

  Widget _buildGoogleButton() {
    return OutlinedButton(
      onPressed: _isAnyLoading ? null : _signInWithGoogle,
      child: _isGoogleLoading
          ? SizedBox(
              width: 22,
              height: 22,
              child: CircularProgressIndicator(
                strokeWidth: 2.5,
                color: Theme.of(context).colorScheme.primary,
              ),
            )
          : const Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                _GoogleLogoIcon(),
                SizedBox(width: 10),
                Text('Google로 계속하기'),
              ],
            ),
    );
  }

  /// Google 로그인 약관 동의 안내 문구.
  ///
  /// [PM] Apple/Google 스토어 심사 기준에 맞게 소셜 로그인 시 약관 동의를
  /// 암묵적으로 처리함을 사용자에게 명시합니다.
  Widget _buildGoogleDisclaimer() {
    return Text(
      'Google 로그인 시 서비스 이용약관 및 개인정보 처리방침에\n동의한 것으로 간주됩니다.',
      textAlign: TextAlign.center,
      style: TextStyle(
        fontSize: 11,
        color: Colors.grey.shade400,
        height: 1.6,
      ),
    );
  }

  /// 로그인 ↔ 회원가입 모드 전환 행.
  Widget _buildToggleModeRow() {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        AnimatedSwitcher(
          duration: const Duration(milliseconds: 200),
          child: Text(
            _isLoginMode ? '아직 계정이 없으신가요?' : '이미 계정이 있으신가요?',
            key: ValueKey(_isLoginMode),
            style: TextStyle(fontSize: 14, color: Colors.grey.shade500),
          ),
        ),
        TextButton(
          onPressed: _isAnyLoading ? null : _toggleMode,
          style: TextButton.styleFrom(
            padding: const EdgeInsets.symmetric(horizontal: 6),
            minimumSize: Size.zero,
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            foregroundColor: kSecondary,
            textStyle: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700),
          ),
          child: AnimatedSwitcher(
            duration: const Duration(milliseconds: 200),
            child: Text(
              _isLoginMode ? '회원가입' : '로그인',
              key: ValueKey(_isLoginMode),
            ),
          ),
        ),
      ],
    );
  }
}

// ── _ForgotPasswordDialog ─────────────────────────────────────────────────────

/// 비밀번호 재설정 다이얼로그.
///
/// [QA] StatefulWidget으로 분리하여 TextEditingController의 dispose() 보장.
class _ForgotPasswordDialog extends StatefulWidget {
  const _ForgotPasswordDialog({required this.authService});

  final AuthService authService;

  @override
  State<_ForgotPasswordDialog> createState() => _ForgotPasswordDialogState();
}

class _ForgotPasswordDialogState extends State<_ForgotPasswordDialog> {
  final _formKey = GlobalKey<FormState>();
  final _controller = TextEditingController();
  bool _isLoading = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;

    setState(() => _isLoading = true);
    try {
      await widget.authService.sendPasswordResetEmail(_controller.text.trim());
      if (!mounted) return;
      final messenger = ScaffoldMessenger.of(context);
      Navigator.pop(context);
      messenger.showSnackBar(
        _buildSnackBar('재설정 링크를 전송했습니다.', isError: false),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() => _isLoading = false);
      ScaffoldMessenger.of(context).showSnackBar(_buildSnackBar(_parseError(e)));
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('비밀번호 재설정'),
      content: Form(
        key: _formKey,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '가입한 이메일 주소를 입력하면\n재설정 링크를 보내드립니다.',
              style: TextStyle(fontSize: 13, color: Colors.grey.shade600, height: 1.5),
            ),
            const SizedBox(height: 16),
            TextFormField(
              controller: _controller,
              keyboardType: TextInputType.emailAddress,
              textInputAction: TextInputAction.done,
              enabled: !_isLoading,
              onFieldSubmitted: (_) => _submit(),
              decoration: const InputDecoration(
                labelText: '이메일',
                hintText: 'example@email.com',
                prefixIcon: Icon(Icons.email_outlined),
              ),
              validator: (value) {
                if (value == null || value.trim().isEmpty) return '이메일을 입력해주세요.';
                if (!RegExp(r'^[\w-.]+@([\w-]+\.)+[\w-]{2,}$').hasMatch(value.trim())) {
                  return '올바른 이메일 형식이 아닙니다.';
                }
                return null;
              },
            ),
          ],
        ),
      ),
      actionsPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      actions: [
        OutlinedButton(
          onPressed: _isLoading ? null : () => Navigator.pop(context),
          style: OutlinedButton.styleFrom(
            minimumSize: const Size(72, 44),
            side: const BorderSide(color: kBorderColor, width: 1.5),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
          ),
          child: const Text('취소'),
        ),
        const SizedBox(width: 8),
        ElevatedButton(
          onPressed: _isLoading ? null : _submit,
          style: ElevatedButton.styleFrom(
            minimumSize: const Size(72, 44),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
          ),
          child: _isLoading
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2, color: kSurface),
                )
              : const Text('전송'),
        ),
      ],
    );
  }
}

// ── 파일 전역 헬퍼 ──────────────────────────────────────────────────────────────

String _parseError(Object e) => e.toString().replaceAll('Exception: ', '');

SnackBar _buildSnackBar(String message, {bool isError = true}) {
  return SnackBar(
    content: Text(message),
    backgroundColor: isError ? const Color(0xFFD32F2F) : const Color(0xFF1B5E20),
    margin: const EdgeInsets.all(16),
  );
}

// ── _GoogleLogoIcon ───────────────────────────────────────────────────────────

class _GoogleLogoIcon extends StatelessWidget {
  const _GoogleLogoIcon();

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 22,
      height: 22,
      child: CustomPaint(painter: _GoogleLogoPainter()),
    );
  }
}

class _GoogleLogoPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final cx = size.width / 2;
    final cy = size.height / 2;
    final r = size.width / 2;
    final rect = Rect.fromCircle(center: Offset(cx, cy), radius: r);
    final sw = size.width * 0.18;

    Paint arc(Color color) => Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = sw
      ..strokeCap = StrokeCap.round;

    canvas.drawArc(rect, -1.4, 1.6, false, arc(const Color(0xFF4285F4)));
    canvas.drawArc(rect, -2.8, 1.4, false, arc(const Color(0xFFEA4335)));
    canvas.drawArc(rect, 2.2,  1.0, false, arc(const Color(0xFFFBBC05)));
    canvas.drawArc(rect, 3.2,  0.7, false, arc(const Color(0xFF34A853)));

    canvas.drawLine(
      Offset(cx - r * 0.05, cy + r * 0.07),
      Offset(cx + r * 0.72, cy + r * 0.07),
      Paint()
        ..color = const Color(0xFF4285F4)
        ..strokeWidth = sw
        ..strokeCap = StrokeCap.round,
    );
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
