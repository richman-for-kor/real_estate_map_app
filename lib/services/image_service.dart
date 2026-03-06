import 'dart:io';

import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_image_compress/flutter_image_compress.dart';

/// 이미지 업로드 파이프라인 결과.
///
/// - [originalUrl] Storage `{basePath}/{uid}_original.jpg` 다운로드 URL
///   → Firestore에 저장, 이미지 뷰어 팝업에서 사용
/// - [thumbUrl] Storage `{basePath}/{uid}_thumb.jpg` 다운로드 URL
///   → Auth.photoURL에 저장, 아바타·목록 렌더링에 사용
class ImageUploadResult {
  const ImageUploadResult({required this.originalUrl, required this.thumbUrl});

  final String originalUrl;
  final String thumbUrl;
}

/// 이미지 압축 · 업로드 파이프라인.
///
/// ```
/// 원본 File
///  ├─ compress(1080×1080, q80) → Storage `{basePath}/{uid}_original.jpg`
///  └─ compress(200×200,  q60) → Storage `{basePath}/{uid}_thumb.jpg`
/// ```
///
/// [설계 원칙]
/// - 인스턴스화 금지 (static 메서드만 제공)
/// - Storage 업로드는 Future.wait 병렬 처리로 레이턴시 최소화
/// - 임시 파일은 finally 블록에서 반드시 정리
class ImageService {
  const ImageService._();

  static final _storage = FirebaseStorage.instance;

  // ── 프로필 이미지 파이프라인 ──────────────────────────────────────────────────

  /// 원본 [File] → 압축 + 썸네일 생성 + Storage 병렬 업로드.
  ///
  /// [basePath] Storage 경로 접두사 (기본값: 'users')
  ///
  /// Throws: [Exception] — 압축 실패 / Storage 업로드 실패 시
  static Future<ImageUploadResult> uploadProfileImages(
    File sourceFile,
    String uid, {
    String basePath = 'users',
  }) async {
    final tmpDir = Directory.systemTemp.path;
    // 타임스탬프를 파일명에 포함 — 동일 uid 동시 호출 시 파일명 충돌(race condition) 방지
    final ts = DateTime.now().millisecondsSinceEpoch;

    // 1. 두 가지 압축 버전 순차 생성
    //    (flutter_image_compress 내부가 이미 isolate를 사용하므로 UI 블로킹 없음)
    final originalFile = await _compress(
      source: sourceFile,
      target: '$tmpDir/${uid}_${ts}_original_tmp.jpg',
      maxSize: 1080,
      quality: 80,
    );

    final thumbFile = await _compress(
      source: sourceFile,
      target: '$tmpDir/${uid}_${ts}_thumb_tmp.jpg',
      maxSize: 200,
      quality: 60,
    );

    if (originalFile == null || thumbFile == null) {
      throw Exception('이미지 압축에 실패했습니다.');
    }

    // 2. Storage 병렬 업로드 (두 파일 동시 전송으로 총 시간 절감)
    try {
      final meta = SettableMetadata(contentType: 'image/jpeg');
      final uploads = await Future.wait([
        _storage
            .ref('$basePath/${uid}_original.jpg')
            .putFile(originalFile, meta),
        _storage.ref('$basePath/${uid}_thumb.jpg').putFile(thumbFile, meta),
      ]);

      final urls = await Future.wait([
        uploads[0].ref.getDownloadURL(),
        uploads[1].ref.getDownloadURL(),
      ]);

      debugPrint('[ImageService] ✅ 업로드 완료');
      debugPrint('[ImageService]   original: ${urls[0].substring(0, 60)}...');
      debugPrint('[ImageService]   thumb   : ${urls[1].substring(0, 60)}...');

      return ImageUploadResult(originalUrl: urls[0], thumbUrl: urls[1]);
    } catch (e) {
      debugPrint('[Firebase Storage 에러]: $e');
      rethrow;
    } finally {
      // 임시 압축 파일 정리 (Storage 업로드 성공·실패 관계없이 실행)
      try {
        originalFile.deleteSync();
        thumbFile.deleteSync();
      } catch (_) {}
    }
  }

  // ── Private ───────────────────────────────────────────────────────────────

  /// flutter_image_compress로 단일 파일 압축 → [File] 반환.
  ///
  /// [maxSize] minWidth / minHeight (장변 기준 최대 픽셀)
  static Future<File?> _compress({
    required File source,
    required String target,
    required int maxSize,
    required int quality,
  }) async {
    final result = await FlutterImageCompress.compressAndGetFile(
      source.absolute.path,
      target,
      minWidth: maxSize,
      minHeight: maxSize,
      quality: quality,
      format: CompressFormat.jpeg,
    );
    if (result == null) return null;
    return File(result.path);
  }
}
