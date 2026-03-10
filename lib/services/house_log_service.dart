import 'dart:io';
import 'dart:typed_data';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter_image_compress/flutter_image_compress.dart';

/// 단지별 임장 로그 저장·조회 서비스.
///
/// Firestore 경로: `users/{uid}/house_logs/{buildingId}/records/{autoId}`
/// Storage 경로  : `users/{uid}/house_logs/{buildingId}/{recordId}_{idx}_{ts}.jpg`
///
/// [아키텍처]
/// - 비즈니스 로직(압축·업로드·저장)을 화면에서 완전히 분리
/// - Future.wait()로 이미지를 병렬 업로드 → 총 업로드 시간 최소화
/// - Stream을 통해 Firestore 실시간 쿼리를 UI에 노출
class HouseLogService {
  final _firestore = FirebaseFirestore.instance;
  final _storage   = FirebaseStorage.instance;
  final _auth      = FirebaseAuth.instance;

  String? get _uid => _auth.currentUser?.uid;
  bool get isAuthenticated => _auth.currentUser != null;

  // ── buildingId 유틸 ──────────────────────────────────────────────────────

  /// 도로명 주소 라벨을 Firestore 문서 ID로 변환.
  ///
  /// 예: "경기도 성남시 분당구 수내동 5" → "경기도_성남시_분당구_수내동_5"
  /// 규칙: 공백→언더스코어, 특수문자 제거, 길이 100자 제한
  static String buildingId(String label) {
    final processed = label
        .trim()
        .replaceAll(RegExp(r'\s+'), '_')
        .replaceAll(RegExp(r'[^\w가-힣_]'), '');
    return processed.substring(0, processed.length.clamp(0, 100));
  }

  // ── 저장 파이프라인 ───────────────────────────────────────────────────────

  /// Quick Input 임장 로그를 Storage + Firestore에 저장.
  ///
  /// [플로우]
  ///   1. flutter_image_compress — 이미지 압축 (1080px / quality 80)
  ///   2. Firebase Storage — 병렬 업로드 후 downloadUrl 수집
  ///   3. Firestore — text + mediaUrls + serverTimestamp 원자 저장
  Future<void> saveLog({
    required String buildingId,
    required String text,
    required List<File> imageFiles,
  }) async {
    final uid = _uid;
    if (uid == null) throw Exception('로그인이 필요합니다.');

    // 신규 레코드 레퍼런스 (autoId 미리 확보 → Storage 경로에 재사용)
    final recordRef = _firestore
        .collection('users')
        .doc(uid)
        .collection('house_logs')
        .doc(buildingId)
        .collection('records')
        .doc();
    final recordId = recordRef.id;
    final ts = DateTime.now().millisecondsSinceEpoch;

    // ── Phase 1: 이미지 압축 + Storage 병렬 업로드 ────────────────────────
    // 업로드 성공한 ref를 추적하여 Firestore 저장 실패 시 롤백합니다.
    final uploadedRefs = <Reference>[];
    final List<String> mediaUrls;
    try {
      mediaUrls = await Future.wait(
        imageFiles.asMap().entries.map((entry) async {
          final idx  = entry.key;
          final file = entry.value;

          // 압축 (실패 시 원본 bytes 폴백)
          final Uint8List bytes = await _compressImage(file);

          // Storage 업로드
          final path = 'users/$uid/house_logs/$buildingId'
              '/${recordId}_${idx}_$ts.jpg';
          final ref = _storage.ref(path);
          await ref.putData(
            bytes,
            SettableMetadata(contentType: 'image/jpeg'),
          );
          final url = await ref.getDownloadURL();
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

    // ── Phase 2: Firestore 원자 저장 ─────────────────────────────────────
    try {
      await recordRef.set({
        'text':      text,
        'mediaUrls': mediaUrls,
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

  /// 이미지 압축 (1MB 이하 보장). 실패 시 원본 bytes 반환.
  ///
  /// 1차: 1080px / quality 80 → 결과가 1MB 초과이면
  /// 2차: 1080px / quality 55 로 재압축.
  Future<Uint8List> _compressImage(File file) async {
    const maxBytes = 1024 * 1024; // 1 MB
    try {
      Uint8List? result = await FlutterImageCompress.compressWithFile(
        file.path,
        minWidth:  1080,
        minHeight: 1080,
        quality:   80,
        format:    CompressFormat.jpeg,
      );
      if (result != null && result.isNotEmpty) {
        if (result.length <= maxBytes) return result;
        // 1MB 초과 → 품질을 낮춰 재압축
        final retry = await FlutterImageCompress.compressWithFile(
          file.path,
          minWidth:  1080,
          minHeight: 1080,
          quality:   55,
          format:    CompressFormat.jpeg,
        );
        if (retry != null && retry.isNotEmpty) return retry;
      }
    } catch (_) {
      // 압축 실패(비지원 포맷 등) → 원본 사용
    }
    return file.readAsBytes();
  }

  // ── 수정 ────────────────────────────────────────────────────────────────

  /// 임장 로그를 수정합니다.
  ///
  /// [existingUrls] : 유지할 기존 이미지 URL 목록
  /// [newImageFiles]: 새로 추가할 이미지 파일 목록
  /// [deletedUrls]  : Storage에서 삭제할 기존 이미지 URL 목록
  Future<void> updateLog({
    required String buildingId,
    required String recordId,
    required String text,
    required List<String> existingUrls,
    required List<File> newImageFiles,
    required List<String> deletedUrls,
  }) async {
    final uid = _uid;
    if (uid == null) throw Exception('로그인이 필요합니다.');

    final recordRef = _firestore
        .collection('users')
        .doc(uid)
        .collection('house_logs')
        .doc(buildingId)
        .collection('records')
        .doc(recordId);

    // 삭제 요청된 이미지 Storage에서 제거
    for (final url in deletedUrls) {
      try {
        await _storage.refFromURL(url).delete();
      } catch (_) {}
    }

    // 새 이미지 업로드
    final ts = DateTime.now().millisecondsSinceEpoch;
    final newUrls = <String>[];
    for (int i = 0; i < newImageFiles.length; i++) {
      final bytes = await _compressImage(newImageFiles[i]);
      final path =
          'users/$uid/house_logs/$buildingId/${recordId}_edit_${i}_$ts.jpg';
      final ref = _storage.ref(path);
      await ref.putData(bytes, SettableMetadata(contentType: 'image/jpeg'));
      newUrls.add(await ref.getDownloadURL());
    }

    // Firestore 업데이트
    await recordRef.update({
      'text': text,
      'mediaUrls': [...existingUrls, ...newUrls],
      'updatedAt': FieldValue.serverTimestamp(),
    });
  }

  // ── 삭제 ────────────────────────────────────────────────────────────────

  /// 임장 로그를 삭제합니다 (Firestore 문서 + Storage 파일 모두 제거).
  Future<void> deleteLog({
    required String buildingId,
    required String recordId,
    required List<String> mediaUrls,
  }) async {
    final uid = _uid;
    if (uid == null) throw Exception('로그인이 필요합니다.');

    for (final url in mediaUrls) {
      try {
        await _storage.refFromURL(url).delete();
      } catch (_) {}
    }

    await _firestore
        .collection('users')
        .doc(uid)
        .collection('house_logs')
        .doc(buildingId)
        .collection('records')
        .doc(recordId)
        .delete();
  }

  // ── 실시간 쿼리 Stream ───────────────────────────────────────────────────

  /// 특정 건물에 대한 내 임장 기록 Stream (최신순 20건).
  ///
  /// 비로그인 상태이면 빈 Stream 반환 — UI에서 빈 상태를 처리.
  Stream<QuerySnapshot<Map<String, dynamic>>> logsStream(String buildingId) {
    final uid = _uid;
    if (uid == null) return const Stream.empty();

    return _firestore
        .collection('users')
        .doc(uid)
        .collection('house_logs')
        .doc(buildingId)
        .collection('records')
        .orderBy('createdAt', descending: true)
        .limit(20)
        .snapshots();
  }
}
