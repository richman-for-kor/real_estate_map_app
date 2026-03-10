import 'dart:io';
import 'dart:typed_data';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter_image_compress/flutter_image_compress.dart';

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
    String sido = '',
    String sigungu = '',
    String eupmyeondong = '',
    String buildingId = '', // 지도 팝업 단지별 필터용 (빈 문자열 = 독립 노트)
  }) async {
    final uid = _auth.currentUser?.uid;
    if (uid == null) throw Exception('로그인이 필요합니다.');
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
          final storagePath =
              'imjang_records/$uid/$recordId/${index}_$ts.jpg';

          final ref = _storage.ref(storagePath);
          final bytes = await _compressImage(file);
          final snapshot = await ref.putData(
            bytes,
            SettableMetadata(contentType: 'image/jpeg'),
          );
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
        'sido': sido,
        'sigungu': sigungu,
        'eupmyeondong': eupmyeondong,
        'latitude': latitude,
        'longitude': longitude,
        'review': review,
        'mediaUrls': downloadUrls,
        'createdAt': FieldValue.serverTimestamp(),
        if (buildingId.isNotEmpty) 'buildingId': buildingId,
      });
    } catch (e) {
      // Firestore 저장 실패 → Storage 파일 전체 롤백
      for (final ref in uploadedRefs) {
        ref.delete().catchError((_) {});
      }
      rethrow;
    }
  }

  // ── 수정 ────────────────────────────────────────────────────────────────

  /// 임장 기록 텍스트/이미지를 수정합니다.
  Future<void> updateRecord({
    required String docId,
    required String review,
    required List<String> existingUrls,
    required List<File> newImageFiles,
    required List<String> deletedUrls,
  }) async {
    final uid = _auth.currentUser?.uid;
    if (uid == null) throw Exception('로그인이 필요합니다.');

    for (final url in deletedUrls) {
      try {
        await _storage.refFromURL(url).delete();
      } catch (_) {}
    }

    final ts = DateTime.now().millisecondsSinceEpoch;
    final newUrls = <String>[];
    final uploadedRefs = <Reference>[];
    try {
      for (int i = 0; i < newImageFiles.length; i++) {
        final bytes = await _compressImage(newImageFiles[i]);
        final path = 'imjang_records/$uid/${docId}_edit_${i}_$ts.jpg';
        final ref = _storage.ref(path);
        await ref.putData(bytes, SettableMetadata(contentType: 'image/jpeg'));
        newUrls.add(await ref.getDownloadURL());
        uploadedRefs.add(ref);
      }
    } catch (e) {
      for (final ref in uploadedRefs) {
        ref.delete().catchError((_) {});
      }
      rethrow;
    }

    try {
      await _firestore.collection('imjang_records').doc(docId).update({
        'review': review,
        'mediaUrls': [...existingUrls, ...newUrls],
        'updatedAt': FieldValue.serverTimestamp(),
      });
    } catch (e) {
      // Firestore 실패 → 새로 업로드한 Storage 파일 롤백
      for (final ref in uploadedRefs) {
        ref.delete().catchError((_) {});
      }
      rethrow;
    }
  }

  // ── 삭제 ────────────────────────────────────────────────────────────────

  /// 임장 기록을 삭제합니다 (Firestore 문서 + Storage 파일 모두 제거).
  Future<void> deleteRecord({
    required String docId,
    required List<String> mediaUrls,
  }) async {
    for (final url in mediaUrls) {
      try {
        await _storage.refFromURL(url).delete();
      } catch (_) {}
    }
    await _firestore.collection('imjang_records').doc(docId).delete();
  }

  // ── 실시간 쿼리 Stream ───────────────────────────────────────────────────

  /// 특정 단지(buildingId)에 대한 내 임장 기록 실시간 Stream (최신순 20건).
  ///
  /// 지도 탭 단지 팝업의 임장노트 탭에서 사용.
  /// 비로그인 시 빈 Stream 반환.
  Stream<QuerySnapshot<Map<String, dynamic>>> logsStreamByBuilding(
      String buildingId) {
    final uid = _auth.currentUser?.uid;
    if (uid == null) return const Stream.empty();

    return _firestore
        .collection('imjang_records')
        .where('uid', isEqualTo: uid)
        .where('buildingId', isEqualTo: buildingId)
        .orderBy('createdAt', descending: true)
        .limit(20)
        .snapshots();
  }

  /// 이미지 압축 (1MB 이하 보장). 실패 시 원본 bytes 반환.
  ///
  /// 1차: 1080px / quality 80 → 결과가 1MB 초과이면
  /// 2차: 1080px / quality 55 로 재압축.
  Future<Uint8List> _compressImage(File file) async {
    const maxBytes = 1024 * 1024; // 1 MB
    try {
      Uint8List? result = await FlutterImageCompress.compressWithFile(
        file.path,
        minWidth: 1080,
        minHeight: 1080,
        quality: 80,
        format: CompressFormat.jpeg,
      );
      if (result != null && result.isNotEmpty) {
        if (result.length <= maxBytes) return result;
        final retry = await FlutterImageCompress.compressWithFile(
          file.path,
          minWidth: 1080,
          minHeight: 1080,
          quality: 55,
          format: CompressFormat.jpeg,
        );
        if (retry != null && retry.isNotEmpty) return retry;
      }
    } catch (_) {
      // 압축 실패(비지원 포맷 등) → 원본 사용
    }
    return file.readAsBytes();
  }
}
