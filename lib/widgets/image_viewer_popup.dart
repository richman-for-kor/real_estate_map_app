import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

/// 이미지 뷰어 팝업을 표시합니다.
///
/// [UX] 반투명 검은 배경의 다이얼로그에서 [InteractiveViewer]로
/// Pinch-to-zoom(0.5×~5×)을 지원하며, 배경 탭 또는 X 버튼으로 닫습니다.
///
/// [캐싱] [CachedNetworkImage]가 디스크 캐시를 관리하므로
/// 한 번 로드한 고화질 원본은 다음 열람 시 즉시 표시됩니다.
///
/// ```dart
/// // 사용 예시
/// showImageViewerDialog(context, originalPhotoUrl);
/// ```
void showImageViewerDialog(BuildContext context, String imageUrl) {
  showDialog<void>(
    context: context,
    barrierColor: Colors.black87,
    builder: (ctx) => _ImageViewerDialog(imageUrl: imageUrl),
  );
}

// ── Dialog Widget ──────────────────────────────────────────────────────────

class _ImageViewerDialog extends StatelessWidget {
  const _ImageViewerDialog({required this.imageUrl});

  final String imageUrl;

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: Colors.transparent,
      insetPadding: EdgeInsets.zero,
      child: Stack(
        children: [
          // ── 배경 탭 → 닫기 ──────────────────────────────────────────────
          GestureDetector(
            onTap: () => Navigator.pop(context),
            behavior: HitTestBehavior.opaque,
            child: const SizedBox.expand(),
          ),

          // ── 이미지 (InteractiveViewer로 핀치 줌) ─────────────────────────
          Center(
            child: InteractiveViewer(
              minScale: 0.5,
              maxScale: 5.0,
              child: CachedNetworkImage(
                imageUrl: imageUrl,
                fit: BoxFit.contain,
                // 로딩 중: 흰색 CircularProgressIndicator
                placeholder: (context, url) => const SizedBox(
                  width: 240,
                  height: 240,
                  child: Center(
                    child: CircularProgressIndicator(color: Colors.white),
                  ),
                ),
                // 에러: 깨진 이미지 아이콘
                errorWidget: (context, url, error) => const Icon(
                  Icons.broken_image_rounded,
                  color: Colors.white54,
                  size: 72,
                ),
              ),
            ),
          ),

          // ── 닫기 버튼 (우측 상단, SafeArea 고려) ─────────────────────────
          Positioned(
            top: MediaQuery.of(context).padding.top + 8,
            right: 12,
            child: GestureDetector(
              onTap: () => Navigator.pop(context),
              child: Container(
                width: 36,
                height: 36,
                decoration: const BoxDecoration(
                  color: Colors.black54,
                  shape: BoxShape.circle,
                ),
                child: const Icon(
                  Icons.close_rounded,
                  color: Colors.white,
                  size: 20,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
