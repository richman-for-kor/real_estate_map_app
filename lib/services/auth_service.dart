import 'dart:async';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:flutter/foundation.dart'
    show kIsWeb, TargetPlatform, defaultTargetPlatform, debugPrint;

/// Firebase Auth + Firestore 기반 인증 서비스.
///
/// [서버 개발자 관점 비유]
/// - 이 클래스는 Spring Security의 AuthenticationManager + UserDetailsService에 해당.
/// - FirebaseAuth     = JWT 발급/검증 레이어
/// - users 컬렉션     = 유저 프로필 DB 테이블
/// - login_logs 컬렉션 = access_log 테이블 (non-critical: 실패해도 로그인 불중단)
class AuthService {
  // ── 의존성 ──────────────────────────────────────────────────────────────────
  final FirebaseAuth _auth = FirebaseAuth.instance;
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;

  // ── Firestore 컬렉션 경로 상수 ──────────────────────────────────────────────
  static const String _kUsers = 'users';
  static const String _kLoginLogs = 'login_logs';

  // ── 공개 스트림 / 게터 ────────────────────────────────────────────────────────

  /// Firebase Auth 인증 상태 변화 스트림.
  /// [비유] WebSocket으로 세션 상태를 실시간 push받는 것과 동일.
  Stream<User?> get authStateChanges => _auth.authStateChanges();

  /// 현재 로그인된 Firebase User. 미로그인 시 null.
  User? get currentUser => _auth.currentUser;

  // ── Public API ─────────────────────────────────────────────────────────────

  /// 이메일/비밀번호로 로그인.
  ///
  /// [flow]
  /// 1. Firebase Auth 인증
  /// 2. 소프트 딜리트 여부 확인 (탈퇴 계정 차단)
  /// 3. 로그인 로그 기록 (non-critical: 실패해도 로그인 성공 유지)
  ///
  /// Throws [Exception] — 사용자 친화적 한국어 메시지 포함.
  Future<UserCredential> signInWithEmail(String email, String password) async {
    try {
      final credential = await _auth.signInWithEmailAndPassword(
        email: email.trim(),
        password: password,
      );

      await _checkSoftDeleted(credential.user!.uid);
      unawaited(_createLoginLog(credential.user!.uid)); // non-critical

      return credential;
    } on FirebaseAuthException catch (e) {
      throw _handleAuthException(e);
    } on Exception {
      rethrow; // _checkSoftDeleted에서 던진 탈퇴 계정 예외 등 재전파
    }
  }

  /// 이메일/비밀번호로 신규 회원가입.
  ///
  /// [flow]
  /// 1. Firebase Auth 계정 생성
  /// 2. displayName 업데이트
  /// 3. Firestore users 문서 생성 (termsAgreed, agreedAt 포함)
  /// 4. 로그인 로그 기록 (non-critical)
  ///
  /// [DBA] Auth 계정 생성 후 Firestore 쓰기 실패 시 orphan 계정 방지를 위해
  /// Firebase Auth 계정을 롤백합니다.
  /// [DBA] termsAgreed=true 일 때만 agreedAt 서버 타임스탬프가 저장됩니다.
  ///
  /// Throws [Exception] — 사용자 친화적 한국어 메시지 포함.
  Future<UserCredential> registerWithEmail({
    required String email,
    required String password,
    required String displayName,
    bool termsAgreed = false, // [NEW] 개인정보 수집 동의 여부
  }) async {
    UserCredential? credential;
    try {
      credential = await _auth.createUserWithEmailAndPassword(
        email: email.trim(),
        password: password,
      );

      await credential.user!.updateDisplayName(displayName.trim());
      await _createOrUpdateUserDoc(
        credential.user!,
        isNewUser: true,
        termsAgreed: termsAgreed, // [NEW] DBA: 약관 동의 여부 Firestore에 기록
      );
      unawaited(_createLoginLog(credential.user!.uid)); // non-critical

      return credential;
    } on FirebaseAuthException catch (e) {
      throw _handleAuthException(e);
    } on Exception {
      // Firestore 쓰기 실패 → Auth 계정 롤백하여 orphan 계정 방지
      if (credential != null) {
        await credential.user?.delete().catchError((_) {});
      }
      rethrow;
    }
  }

  /// Google 계정으로 소셜 로그인 / 신규 가입.
  ///
  /// [flow]
  /// 1. Google OAuth 인증 시트 표시
  /// 2. Google idToken → Firebase OAuthCredential 교환
  /// 3. Firebase Auth signIn
  /// 4. 소프트 딜리트 여부 확인
  /// 5. 신규/기존 유저 Firestore 문서 upsert
  /// 6. 로그인 로그 기록 (non-critical)
  ///
  /// Returns null — 사용자가 로그인 시트를 직접 닫은 경우(취소).
  /// Throws [Exception] — 그 외 인증 오류.
  Future<UserCredential?> signInWithGoogle() async {
    try {
      debugPrint('🔑 [GoogleSignIn] Step 1: authenticate() 시작');
      final GoogleSignInAccount googleUser =
          await GoogleSignIn.instance.authenticate();
      debugPrint('🔑 [GoogleSignIn] Step 2: 계정 선택 완료 — email=${googleUser.email}');

      final GoogleSignInAuthentication googleAuth = googleUser.authentication;
      // google_sign_in v7: accessToken 프로퍼티 제거됨 — idToken만 사용
      debugPrint(
        '🔑 [GoogleSignIn] Step 3: idToken=${googleAuth.idToken != null ? '✅ 존재' : '❌ null'}',
      );

      final oauthCredential = GoogleAuthProvider.credential(
        idToken: googleAuth.idToken,
      );

      debugPrint('🔑 [GoogleSignIn] Step 4: Firebase signInWithCredential() 시작');
      final userCredential = await _auth.signInWithCredential(oauthCredential);
      final user = userCredential.user!;
      final isNew = userCredential.additionalUserInfo?.isNewUser ?? false;
      debugPrint('🔑 [GoogleSignIn] Step 5: Firebase 로그인 성공 — uid=${user.uid}, isNewUser=$isNew');

      // [QA & DBA] post-auth 처리(_checkSoftDeleted, _createOrUpdateUserDoc) 실패 시
      // Firebase에는 로그인된 상태가 남아 StreamBuilder가 MapScreen으로 진입하는 문제를 방지합니다.
      // 실패 시 signOut()을 호출하여 Firebase 세션을 정리한 뒤 예외를 재전파합니다.
      // [비유] DB 트랜잭션 실패 시 이미 발급된 세션 토큰을 무효화하는 것과 동일.
      try {
        debugPrint('🔑 [GoogleSignIn] Step 6: _checkSoftDeleted() 시작');
        await _checkSoftDeleted(user.uid);
        debugPrint('🔑 [GoogleSignIn] Step 7: _createOrUpdateUserDoc() 시작');
        await _createOrUpdateUserDoc(
          user,
          isNewUser: isNew,
          termsAgreed: isNew, // Google 신규 가입 시 약관 동의로 간주
        );
        debugPrint('🔑 [GoogleSignIn] Step 8: post-auth 처리 완료 ✅');
      } on Exception catch (e) {
        // _checkSoftDeleted는 내부에서 signOut()을 호출하므로 중복 호출은 harmless.
        debugPrint('🔥 [GoogleSignIn] post-auth 실패 → signOut() 호출\n상세 에러: $e');
        await signOut().catchError((_) {});
        rethrow;
      }

      unawaited(_createLoginLog(user.uid)); // non-critical
      return userCredential;
    } on GoogleSignInException catch (e) {
      // 사용자가 직접 취소한 경우 null 반환 (에러 아님)
      if (e.code == GoogleSignInExceptionCode.canceled) return null;
      debugPrint('🔥 [GoogleSignIn] GoogleSignInException: code=${e.code}, description=${e.description}');
      throw Exception('Google 로그인 오류: ${e.description}');
    } on FirebaseAuthException catch (e) {
      debugPrint('🔥 [GoogleSignIn] FirebaseAuthException: code=${e.code}, message=${e.message}\n상세: $e');
      throw _handleAuthException(e);
    } on Exception catch (e) {
      debugPrint('🔥 [GoogleSignIn] 알 수 없는 Exception: $e');
      rethrow;
    }
  }

  /// 로그아웃.
  ///
  /// Google 세션과 Firebase 세션을 순서대로 종료합니다.
  /// Google signOut 실패는 무시하고 Firebase signOut을 반드시 보장합니다.
  Future<void> signOut() async {
    await GoogleSignIn.instance.signOut().catchError((_) {});
    await _auth.signOut();
  }

  /// 소프트 딜리트 (회원 탈퇴).
  ///
  /// Firebase Auth 계정은 보존하고, Firestore users 문서에 deletedAt 타임스탬프를
  /// 기록한 뒤 세션을 종료합니다.
  /// [비유] DB의 deleted_at 필드 업데이트 후 세션 무효화(로그아웃)와 동일.
  ///
  /// Throws [Exception] — 미로그인 상태이거나 Firestore 업데이트 실패 시.
  Future<void> softDeleteCurrentUser() async {
    final user = _auth.currentUser;
    if (user == null) throw Exception('로그인이 필요합니다.');

    try {
      // set(merge:true) — update()는 문서가 없으면 NOT_FOUND 에러 발생.
      // 소프트 딜리트는 문서 유무와 관계없이 안전하게 동작해야 하므로 merge 사용.
      await _firestore.collection(_kUsers).doc(user.uid).set(
        {
          'deletedAt': FieldValue.serverTimestamp(),
          'updatedAt': FieldValue.serverTimestamp(),
        },
        SetOptions(merge: true),
      );
      await signOut();
    } on FirebaseException catch (e) {
      throw Exception('회원 탈퇴 처리 중 오류가 발생했습니다. (${e.code})');
    }
  }

  /// 비밀번호 재설정 이메일 발송.
  ///
  /// Throws [Exception] — 등록되지 않은 이메일이거나 발송 실패 시.
  Future<void> sendPasswordResetEmail(String email) async {
    try {
      await _auth.sendPasswordResetEmail(email: email.trim());
    } on FirebaseAuthException catch (e) {
      throw _handleAuthException(e);
    }
  }

  // ── Private Helpers ───────────────────────────────────────────────────────

  /// 소프트 딜리트 여부 검증.
  ///
  /// [비유] 로그인 필터에서 deleted_at IS NOT NULL 계정을 차단하는 인터셉터.
  /// Firestore 조회 실패(네트워크 오류 등) 시 안전을 위해 예외를 외부로 전파합니다.
  Future<void> _checkSoftDeleted(String uid) async {
    try {
      final doc = await _firestore.collection(_kUsers).doc(uid).get();
      debugPrint(
        '🔍 [CheckSoftDeleted] uid=$uid, exists=${doc.exists}, '
        'deletedAt=${doc.data()?['deletedAt']}',
      );
      if (doc.exists && doc.data()?['deletedAt'] != null) {
        await signOut();
        throw Exception('이미 탈퇴한 계정입니다.');
      }
    } on FirebaseException catch (e) {
      debugPrint('🔥 [CheckSoftDeleted] FirebaseException: code=${e.code}, message=${e.message}\n상세: $e');
      throw Exception('계정 상태 확인 중 오류가 발생했습니다. (${e.code})');
    }
  }

  /// Firestore users 문서 upsert (생성 또는 갱신).
  ///
  /// [DBA 설계]
  /// - 신규 유저: 전체 필드(createdAt, role, termsAgreed, agreedAt 포함) 문서 신규 생성
  /// - 기존 유저: set(merge:true)로 변경 가능 필드만 갱신.
  ///   update() 대신 set(merge:true)를 사용하는 이유는 문서가 존재하지 않을 때도
  ///   안전하게 동작하기 때문입니다.
  /// [비유] INSERT ... ON DUPLICATE KEY UPDATE (MySQL) / upsert (MongoDB)
  Future<void> _createOrUpdateUserDoc(
    User user, {
    required bool isNewUser,
    bool termsAgreed = false, // [NEW] 신규 가입 시에만 의미 있는 파라미터
  }) async {
    try {
      final docRef = _firestore.collection(_kUsers).doc(user.uid);
      final now = FieldValue.serverTimestamp();

      if (isNewUser) {
        await docRef.set({
          'uid': user.uid,
          'email': user.email,
          'displayName': user.displayName,
          'photoUrl': user.photoURL,
          'role': 'user',
          'deletedAt': null,
          // [DBA] 약관 동의 여부 및 동의 시점 기록 — 법적 근거 보관 목적
          'termsAgreed': termsAgreed,
          'agreedAt': termsAgreed ? FieldValue.serverTimestamp() : null,
          'createdAt': now,
          'updatedAt': now,
        });
      } else {
        // merge:true — 문서 없어도 안전 (update()는 문서 없으면 NOT_FOUND 에러)
        await docRef.set(
          {
            'email': user.email,
            'displayName': user.displayName,
            'photoUrl': user.photoURL,
            'updatedAt': now,
          },
          SetOptions(merge: true),
        );
      }
    } on FirebaseException catch (e) {
      throw Exception('유저 정보 저장 중 오류가 발생했습니다. (${e.code})');
    }
  }

  /// login_logs 컬렉션에 로그인 이벤트 기록.
  ///
  /// [Non-Critical] unawaited로 호출됩니다.
  /// 로그 기록 실패가 로그인 플로우를 중단시켜서는 안 되므로
  /// 내부에서 에러를 흡수하고 외부로 전파하지 않습니다.
  /// [비유] access_log INSERT 실패가 API 응답을 500으로 만들면 안 되는 것과 동일.
  Future<void> _createLoginLog(String uid) async {
    try {
      await _firestore.collection(_kLoginLogs).add({
        'uid': uid,
        'loginAt': FieldValue.serverTimestamp(),
        'platform': _resolvePlatformName(),
      });
    } on Exception catch (_) {
      // non-critical: 로그 기록 실패는 의도적으로 무시
    }
  }

  /// 현재 실행 플랫폼 이름을 문자열로 반환.
  String _resolvePlatformName() {
    if (kIsWeb) return 'web';
    switch (defaultTargetPlatform) {
      case TargetPlatform.android:
        return 'android';
      case TargetPlatform.iOS:
        return 'ios';
      case TargetPlatform.windows:
        return 'windows';
      case TargetPlatform.macOS:
        return 'macos';
      case TargetPlatform.linux:
        return 'linux';
      default:
        return 'unknown';
    }
  }

  /// FirebaseAuthException → 사용자 친화적 [Exception] 변환.
  ///
  /// [비유] Spring의 @ExceptionHandler + ErrorResponse DTO와 동일.
  /// Firebase SDK의 내부 에러 코드를 UI 레이어가 바로 표시할 수 있는
  /// 한국어 메시지로 변환합니다.
  Exception _handleAuthException(FirebaseAuthException e) {
    switch (e.code) {
      // ── 로그인 관련 ──────────────────────────────────────────────────────────
      case 'user-not-found':
        return Exception('등록되지 않은 이메일입니다.');
      case 'wrong-password':
      case 'invalid-credential':
        return Exception('이메일 또는 비밀번호가 올바르지 않습니다.');
      case 'user-disabled':
        return Exception('비활성화된 계정입니다. 관리자에게 문의하세요.');

      // ── 회원가입 관련 ─────────────────────────────────────────────────────────
      case 'email-already-in-use':
        return Exception('이미 사용 중인 이메일입니다.');
      case 'weak-password':
        return Exception('비밀번호는 6자 이상이어야 합니다.');
      case 'invalid-email':
        return Exception('유효하지 않은 이메일 형식입니다.');
      case 'operation-not-allowed':
        return Exception('지원하지 않는 로그인 방식입니다.');

      // ── 소셜 로그인 관련 ──────────────────────────────────────────────────────
      case 'account-exists-with-different-credential':
        return Exception('동일 이메일로 가입된 다른 로그인 방식이 존재합니다.');
      case 'credential-already-in-use':
        return Exception('이미 다른 계정에 연결된 인증 정보입니다.');

      // ── 재인증 / 보안 관련 ────────────────────────────────────────────────────
      case 'requires-recent-login':
        return Exception('보안을 위해 재로그인이 필요합니다.');
      case 'too-many-requests':
        return Exception('요청이 너무 많습니다. 잠시 후 다시 시도해주세요.');

      // ── 이메일 액션 코드 관련 ─────────────────────────────────────────────────
      case 'expired-action-code':
        return Exception('인증 링크가 만료되었습니다. 다시 요청해주세요.');
      case 'invalid-action-code':
        return Exception('유효하지 않은 인증 링크입니다.');

      // ── 네트워크 / 기타 ───────────────────────────────────────────────────────
      case 'network-request-failed':
        return Exception('네트워크 연결을 확인해주세요.');
      default:
        return Exception('인증 오류가 발생했습니다. (${e.code})');
    }
  }
}
