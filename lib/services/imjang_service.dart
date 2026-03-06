import 'dart:io';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_storage/firebase_storage.dart';

/// 임장 기록 저장 서비스.
///
/// [CTO] Storage 병렬 업로드 → Firestore 저장의 2-phase 파이프라인.
/// Future.wait()으로 미디어 파일을 동시에 업로드하여 지연 시간을 최소화합니다.
///
/// Firestore 컬렉션: `imjang_records/{recordId}`
/// Storage 경로    : `imjang_records/{uid}/{recordId}/{index}_{ts}.{ext}`
class ImjangService {
  final _firestore = FirebaseFirestore.instance;
  final _storage = FirebaseStorage.instance;
  final _auth = FirebaseAuth.instance;

  /// 임장 기록을 Storage에 업로드하고 Firestore에 저장합니다.
  ///
  /// [title]                 : 노트 제목
  /// [address]               : 카카오 검색으로 선택된 주소 문자열
  /// [region]                : 필터용 지역 구분 ('서울'·'경기/인천'·'부산/경남'·'지방')
  /// [latitude], [longitude] : 기록 위치 좌표
  /// [review]                : 사용자가 작성한 텍스트 후기
  /// [mediaFiles]            : 첨부 이미지·동영상 File 목록 (빈 리스트 허용)
  ///
  /// 성공 시 void 반환, 실패 시 예외를 throw합니다.
  Future<void> saveImjangRecord({
    required String title,
    required String address,
    required String region,
    required double latitude,
    required double longitude,
    required String review,
    required List<File> mediaFiles,
  }) async {
    final uid = _auth.currentUser?.uid ?? 'anonymous';
    final recordRef = _firestore.collection('imjang_records').doc();
    final recordId = recordRef.id;
    final ts = DateTime.now().millisecondsSinceEpoch;

    // ── Phase 1: 미디어 파일 병렬 업로드 ────────────────────────────────────
    // [CTO] Future.wait()로 모든 파일을 동시에 업로드하여 순차 업로드 대비
    //       업로드 시간을 (파일 수 × 단위 시간)에서 max(단위 시간)으로 단축합니다.
    // 업로드 성공한 ref를 추적하여 Firestore 저장 실패 시 롤백합니다.
    final uploadedRefs = <Reference>[];
    final List<String> downloadUrls;
    try {
      downloadUrls = await Future.wait(
        mediaFiles.asMap().entries.map((entry) async {
          final index = entry.key;
          final file = entry.value;
          // split('.').last는 경로에 '.'이 없으면 파일명 전체를 반환 — 안전한 폴백 적용
          final pathStr = file.path;
          final dotIdx = pathStr.lastIndexOf('.');
          final ext = dotIdx != -1
              ? pathStr.substring(dotIdx + 1).toLowerCase()
              : 'jpg';
          final storagePath =
              'imjang_records/$uid/$recordId/${index}_$ts.$ext';

          final ref = _storage.ref(storagePath);
          final snapshot = await ref.putFile(file);
          final url = await snapshot.ref.getDownloadURL();
          uploadedRefs.add(ref); // 성공한 ref 추적 (롤백용)
          return url;
        }),
      );
    } catch (e) {
      // 일부 업로드 성공 후 나머지 실패 → 이미 업로드된 파일 삭제(고아 파일 방지)
      for (final ref in uploadedRefs) {
        ref.delete().catchError((_) {});
      }
      rethrow;
    }

    // ── Phase 2: Firestore 저장 ──────────────────────────────────────────────
    try {
      await recordRef.set({
        'uid': uid,
        'title': title,
        'address': address,
        'region': region,
        'latitude': latitude,
        'longitude': longitude,
        'review': review,
        'mediaUrls': downloadUrls,
        'createdAt': FieldValue.serverTimestamp(),
      });
    } catch (e) {
      // Firestore 저장 실패 → Storage 파일 전체 롤백
      for (final ref in uploadedRefs) {
        ref.delete().catchError((_) {});
      }
      rethrow;
    }
  }
}
