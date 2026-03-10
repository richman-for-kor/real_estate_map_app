import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:flutter_naver_map/flutter_naver_map.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'firebase_options.dart';
import 'screens/main_tab_screen.dart';
import 'screens/permission_screen.dart';

// ── Google Sign-In 설정 ──────────────────────────────────────────────────────────
// [백엔드] Firebase Console → 인증 → 로그인 제공업체 → Google → 웹 클라이언트 ID
// google_sign_in v7+ 정책: Android에서 initialize()에 serverClientId를 반드시 전달해야 합니다.
// ('serverClientId must be provided on Android' 에러 원인)
const String kGoogleServerClientId =
    '243913496121-ivunebovllv71nftfo4ea7m0ma9mf2uq.apps.googleusercontent.com';

// ── 앱 전역 색상 팔레트 ──────────────────────────────────────────────────────────
// [UX/UI 디자이너] "iOS-style Soft Blue" — 부동산 서비스의 신뢰감·친근함을 시각적으로 전달.
// 부드러운 코너플라워 블루는 현대적인 iOS 감성을, 화이트/오프화이트는 공간감과 명료함을 표현합니다.
const Color kPrimary = Color(0xFF5B8FF9); // Soft Cornflower Blue — 주요 브랜드 컬러 (iOS 액센트)
const Color kPrimaryLight = Color(
  0xFFEBF2FF,
); // Pastel Blue         — 칩 배경·태그
const Color kSecondary = Color(0xFFFF9F6B); // Soft Peach          — 보조 액센트·링크
const Color kSurface = Color(0xFFFFFFFF); // Pure White          — 카드·다이얼로그
const Color kBackground = Color(0xFFF5F7FA); // Near-white          — 배경·필드 Fill
const Color kBorderColor = Color(0xFFEEF0F5); // Very subtle divider — 테두리·구분선
const Color kTextDark = Color(0xFF1C2033); // Near Black          — 본문 텍스트 (not navy)
const Color kTextMuted = Color(0xFF9BA3BA); // Soft Blue-Gray      — 힌트·레이블

/// 앱 진입점.
///
/// [초기화 순서]
/// 1. Flutter 엔진 바인딩 확보
/// 2. Firebase 플랫폼별 초기화
/// 3. Google Sign-In 싱글톤 초기화 (v7.x 필수)
/// 4. SharedPreferences로 온보딩 완료 여부 조회
///
/// [PM] 온보딩 미완료 시 PermissionScreen → 완료 후 MainTabScreen 순으로 라우팅합니다.
/// [QA] 초기화 실패 시 빈 화면이 아닌 구조화된 에러 화면을 표시합니다.
void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // NaverMap SDK 내부에서 GPS null 시 던지는 PlatformException을 전역에서 처리.
  // setLocationTrackingMode() 이후 SDK 내부 async 에서 발생 → try-catch 불가 → 여기서 처리.
  PlatformDispatcher.instance.onError = (error, stack) {
    if (error is PlatformException && error.code == 'LocationError') {
      debugPrint('[GPS] 위치를 가져올 수 없습니다 — NaverMap LocationError 억제');
      return true; // 처리 완료 (앱 크래시 방지)
    }
    return false; // 나머지 에러는 기본 핸들러에 위임
  };

  // env 파일 로드
  await dotenv.load(fileName: ".env");

  final initError = await _initializeApp();

  // [PM] 최초 실행 여부 확인 — 온보딩 완료 플래그 조회
  final prefs = await SharedPreferences.getInstance();
  final onboardingDone = prefs.getBool(kOnboardingCompleteKey) ?? false;

  runApp(MyApp(initError: initError, showPermission: !onboardingDone));
}

/// Firebase 및 외부 SDK 초기화. 실패 시 에러 메시지 문자열을 반환합니다.
///
/// [비유] Spring Boot ApplicationContext 로딩 실패를 graceful하게 처리하는 것과 동일.
/// 성공 시 null, 실패 시 에러 문자열 반환.
Future<String?> _initializeApp() async {
  try {
    await Firebase.initializeApp(
      options: DefaultFirebaseOptions.currentPlatform,
    );
    await GoogleSignIn.instance.initialize(
      serverClientId: kGoogleServerClientId,
    );

    final naverClientId = dotenv.env['NAVER_CLIENT_ID'];
    if (naverClientId == null || naverClientId.isEmpty) {
      throw Exception(
        'NAVER_CLIENT_ID가 .env에 설정되지 않았습니다.\n'
        'Naver Cloud Platform 콘솔에서 발급한 Client ID를 입력하세요.',
      );
    }

    // flutter_naver_map 1.4.4: FlutterNaverMap().init() → NcpKeyClient 사용 (NCP 최신 인증)
    // NaverMapSdk.instance.initialize() 는 deprecated — NaverCloudPlatformClient(구버전) 사용으로 401 발생
    await FlutterNaverMap().init(
      clientId: naverClientId,
      onAuthFailed: (ex) {
        debugPrint('[네이버 지도 인증 에러]: $ex');
      },
    );

    return null;
  } catch (e) {
    return '앱 초기화에 실패했습니다.\n$e';
  }
}

/// 앱 루트 위젯.
///
/// [PM] Deferred Auth + 온보딩 권한 라우팅 구조.
/// - 최초 실행(showPermission: true)  → PermissionScreen
/// - 재실행(showPermission: false)    → MainTabScreen (로그인 불필요)
/// - SDK 초기화 실패(initError != null) → _InitErrorScreen (최우선)
class MyApp extends StatelessWidget {
  const MyApp({super.key, this.initError, required this.showPermission});

  final String? initError;

  /// true = 온보딩 미완료 → PermissionScreen 먼저 표시
  final bool showPermission;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '집로그',
      debugShowCheckedModeBanner: false,
      theme: _buildTheme(),
      home: initError != null
          ? _InitErrorScreen(message: initError!)
          : showPermission
          ? const PermissionScreen()
          : const MainTabScreen(),
    );
  }

  /// 전역 ThemeData 빌드.
  ///
  /// [UX/UI 디자이너] iOS 스타일 컴포넌트별 테마를 중앙에서 정의하여 일관된 디자인 언어를 보장합니다.
  /// [퍼블리셔] 각 위젯에서 스타일을 하드코딩하지 않고 Theme.of(context)로 참조합니다.
  ThemeData _buildTheme() {
    final colorScheme =
        ColorScheme.fromSeed(
          seedColor: const Color(0xFF5B8FF9),
          brightness: Brightness.light,
        ).copyWith(
          primary: kPrimary,
          onPrimary: kSurface,
          primaryContainer: kPrimaryLight,
          onPrimaryContainer: kTextDark,
          secondary: kSecondary,
          onSecondary: kSurface,
          surface: kSurface,
          onSurface: kTextDark,
          surfaceContainerHighest: kBackground,
        );

    return ThemeData(
      useMaterial3: true,
      colorScheme: colorScheme,
      fontFamily: 'Roboto',
      scaffoldBackgroundColor: kBackground,

      // ── AppBar ────────────────────────────────────────────────────────────────
      // [UX] 화이트 AppBar로 콘텐츠에 집중하는 iOS 스타일 미니멀 디자인.
      appBarTheme: const AppBarTheme(
        backgroundColor: kSurface,
        foregroundColor: kTextDark,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
        titleTextStyle: TextStyle(
          fontFamily: 'Roboto',
          fontSize: 18,
          fontWeight: FontWeight.w700,
          color: kTextDark,
          letterSpacing: -0.3,
        ),
        iconTheme: IconThemeData(color: kTextDark),
      ),

      // ── BottomNavigationBar ───────────────────────────────────────────────────
      bottomNavigationBarTheme: const BottomNavigationBarThemeData(
        backgroundColor: kSurface,
        selectedItemColor: kPrimary,
        unselectedItemColor: kTextMuted,
        type: BottomNavigationBarType.fixed,
        elevation: 0,
      ),

      // ── ElevatedButton ────────────────────────────────────────────────────────
      // [UX] Primary CTA(Call-To-Action) 버튼. 소프트 블루 + 12px radius로 iOS 감성.
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: kPrimary,
          foregroundColor: kSurface,
          disabledBackgroundColor: kBorderColor,
          disabledForegroundColor: kTextMuted,
          elevation: 0,
          shadowColor: Colors.transparent,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
          minimumSize: const Size(double.infinity, 52),
          padding: const EdgeInsets.symmetric(vertical: 14),
          textStyle: const TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.w600,
            letterSpacing: 0.2,
          ),
        ),
      ),

      // ── OutlinedButton ────────────────────────────────────────────────────────
      // [UX] Secondary CTA. kPrimary 테두리 + kPrimary 텍스트, 12px radius.
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: kPrimary,
          backgroundColor: kSurface,
          disabledForegroundColor: kTextMuted,
          side: const BorderSide(color: kPrimary, width: 1.5),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
          minimumSize: const Size(double.infinity, 52),
          padding: const EdgeInsets.symmetric(vertical: 14),
          textStyle: const TextStyle(
            fontSize: 15,
            fontWeight: FontWeight.w500,
            letterSpacing: 0.1,
          ),
        ),
      ),

      // ── TextButton ────────────────────────────────────────────────────────────
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: kSecondary,
          textStyle: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
        ),
      ),

      // ── InputDecoration (TextFormField 전역 스타일) ────────────────────────────
      // [퍼블리셔] 개별 필드에서 스타일을 하드코딩하지 않고 테마에서 일괄 관리합니다.
      // [UX] filled kBackground, 테두리 없음, 포커스 시 kPrimary 테두리.
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: kBackground,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 16,
          vertical: 14,
        ),
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
          borderSide: const BorderSide(color: kPrimary, width: 1.8),
        ),
        errorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: Color(0xFFEF5350)),
        ),
        focusedErrorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: Color(0xFFEF5350), width: 1.8),
        ),
        labelStyle: const TextStyle(fontSize: 14, color: kTextMuted),
        floatingLabelStyle: const TextStyle(
          color: kPrimary,
          fontWeight: FontWeight.w600,
        ),
        hintStyle: const TextStyle(fontSize: 14, color: kTextMuted),
        prefixIconColor: kTextMuted,
        errorStyle: const TextStyle(fontSize: 12),
      ),

      // ── Card ──────────────────────────────────────────────────────────────────
      // [UX] elevation 0, 소프트 그림자는 BoxDecoration으로 직접 적용.
      cardTheme: CardThemeData(
        elevation: 0,
        color: kSurface,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      ),

      // ── SnackBar ──────────────────────────────────────────────────────────────
      // [퍼블리셔] behavior/shape을 전역 설정. 각 호출부는 content와 backgroundColor만 지정.
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        backgroundColor: kPrimary,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        contentTextStyle: const TextStyle(
          fontSize: 14,
          color: kSurface,
          fontWeight: FontWeight.w500,
        ),
      ),

      // ── Dialog ────────────────────────────────────────────────────────────────
      dialogTheme: DialogThemeData(
        backgroundColor: kSurface,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        titleTextStyle: const TextStyle(
          fontFamily: 'Roboto',
          fontSize: 18,
          fontWeight: FontWeight.w700,
          color: kTextDark,
        ),
      ),
    );
  }
}

// ── _InitErrorScreen ──────────────────────────────────────────────────────────

/// Firebase 초기화 실패 시 표시되는 에러 화면.
///
/// [QA] 크래시나 빈 화면 대신 구조화된 에러 메시지를 제공하여
/// 사용자와 개발자 모두 상황을 인지할 수 있게 합니다.
class _InitErrorScreen extends StatelessWidget {
  const _InitErrorScreen({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: kBackground,
      body: Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 32),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Container(
                padding: const EdgeInsets.all(22),
                decoration: BoxDecoration(
                  color: kPrimary.withValues(alpha: 0.08),
                  shape: BoxShape.circle,
                ),
                child: const Icon(
                  Icons.error_outline_rounded,
                  size: 48,
                  color: kPrimary,
                ),
              ),
              const SizedBox(height: 24),
              const Text(
                '앱을 시작할 수 없습니다',
                style: TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.w700,
                  color: kTextDark,
                ),
              ),
              const SizedBox(height: 12),
              Text(
                message,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontSize: 13,
                  color: kTextMuted,
                  height: 1.6,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
