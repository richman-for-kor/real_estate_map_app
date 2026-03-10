import 'dart:io';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../main.dart'
    show kPrimary, kSecondary, kTextDark, kTextMuted, kBorderColor;
import '../services/imjang_service.dart';

// ─────────────────────────────────────────────────────────────────────────────
// 임장 노트 상세 화면
// ─────────────────────────────────────────────────────────────────────────────
//
// [보기 모드]
//   AppBar : 단지명 + 수정(연필) + 삭제(휴지통) 버튼
//   Body   : 날짜 / 후기 텍스트 / 3열 사진 그리드
//   사진 탭 → 전체화면 뷰어 (좌우 스와이프 + 핀치줌)
//
// [편집 모드]
//   텍스트 편집 + 기존 사진 X 삭제 + 새 사진 추가
//   저장 / 취소 버튼 (AppBar)
//
// [서비스]
//   항상 ImjangService (imjang_records 컬렉션) 사용

class ImjangNoteDetailScreen extends StatefulWidget {
  const ImjangNoteDetailScreen({
    super.key,
    required this.text,
    required this.mediaUrls,
    required this.createdAt,
    this.aptName,
    this.docId,
  });

  final String text;
  final List<String> mediaUrls;
  final DateTime createdAt;
  final String? aptName;
  final String? docId;

  @override
  State<ImjangNoteDetailScreen> createState() =>
      _ImjangNoteDetailScreenState();
}

class _ImjangNoteDetailScreenState extends State<ImjangNoteDetailScreen> {
  bool _isEditing = false;
  bool _isSaving = false;

  late TextEditingController _textCtrl;
  late List<String> _currentUrls;        // 현재 표시할 이미지 URL (보기/편집 공용)
  final List<String> _deletedUrls = [];  // 편집 시 삭제 예정 URL
  final List<XFile> _newImages = [];     // 편집 시 새로 추가할 이미지

  bool get _canEdit => widget.docId != null;

  @override
  void initState() {
    super.initState();
    _textCtrl = TextEditingController(text: widget.text);
    _currentUrls = List<String>.from(widget.mediaUrls);
  }

  @override
  void dispose() {
    _textCtrl.dispose();
    super.dispose();
  }

  // ── 저장 ─────────────────────────────────────────────────────────────────

  Future<void> _save() async {
    if (_isSaving) return;
    setState(() => _isSaving = true);
    try {
      final newFiles = _newImages
          .map((x) => File(x.path))
          .toList();

      await ImjangService().updateRecord(
        docId: widget.docId!,
        review: _textCtrl.text.trim(),
        existingUrls: _currentUrls,
        newImageFiles: newFiles,
        deletedUrls: _deletedUrls,
      );

      if (!mounted) return;
      setState(() {
        _isEditing = false;
        _deletedUrls.clear();
        _newImages.clear();
      });
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('저장됐습니다.')),
      );
      // 수정 결과를 부모에게 반환
      Navigator.pop(context, true);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('저장 실패: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  // ── 삭제 ─────────────────────────────────────────────────────────────────

  Future<void> _delete() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('기록 삭제'),
        content: const Text('이 임장 기록을 삭제하시겠습니까?\n사진도 함께 삭제됩니다.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('취소'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: const Text('삭제'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    setState(() => _isSaving = true);
    try {
      await ImjangService().deleteRecord(
        docId: widget.docId!,
        mediaUrls: _currentUrls,
      );
      if (!mounted) return;
      Navigator.pop(context, true);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('삭제 실패: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  // ── 편집 취소 ─────────────────────────────────────────────────────────────

  void _cancelEdit() {
    setState(() {
      _isEditing = false;
      _textCtrl.text = widget.text;
      _currentUrls = List<String>.from(widget.mediaUrls);
      _deletedUrls.clear();
      _newImages.clear();
    });
  }

  // ── 사진 추가 ─────────────────────────────────────────────────────────────

  Future<void> _pickImages() async {
    final picker = ImagePicker();
    final picked = await picker.pickMultiImage(imageQuality: 90);
    if (picked.isNotEmpty && mounted) {
      setState(() => _newImages.addAll(picked));
    }
  }

  // ── 기존 사진 삭제 (편집 모드) ────────────────────────────────────────────

  void _removeExistingImage(int index) {
    final url = _currentUrls[index];
    setState(() {
      _currentUrls.removeAt(index);
      _deletedUrls.add(url);
    });
  }

  // ── 새 사진 삭제 (편집 모드) ──────────────────────────────────────────────

  void _removeNewImage(int index) {
    setState(() => _newImages.removeAt(index));
  }

  // ── 전체화면 뷰어 ─────────────────────────────────────────────────────────

  void _openImageViewer(List<String> urls, int initialIndex) {
    Navigator.push(
      context,
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (_) => _FullscreenViewer(urls: urls, initialIndex: initialIndex),
      ),
    );
  }

  // ── build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      appBar: _buildAppBar(),
      body: _isSaving
          ? const Center(child: CircularProgressIndicator())
          : _buildBody(),
    );
  }

  AppBar _buildAppBar() {
    final title = widget.aptName ?? '임장 노트';
    if (_isEditing) {
      return AppBar(
        backgroundColor: Colors.white,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0.5,
        title: const Text('노트 수정',
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
        leading: TextButton(
          onPressed: _cancelEdit,
          child: const Text('취소', style: TextStyle(color: kTextMuted)),
        ),
        actions: [
          TextButton(
            onPressed: _save,
            child: const Text('저장',
                style: TextStyle(
                    color: kPrimary, fontWeight: FontWeight.w700)),
          ),
        ],
      );
    }
    return AppBar(
      backgroundColor: Colors.white,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      scrolledUnderElevation: 0.5,
      title: Text(
        title,
        style: const TextStyle(
          fontSize: 16,
          fontWeight: FontWeight.w700,
          color: kTextDark,
        ),
      ),
      actions: _canEdit
          ? [
              IconButton(
                icon: const Icon(Icons.edit_outlined, size: 22),
                color: kTextMuted,
                onPressed: () => setState(() => _isEditing = true),
              ),
              IconButton(
                icon: const Icon(Icons.delete_outline_rounded, size: 22),
                color: Colors.red.shade400,
                onPressed: _delete,
              ),
            ]
          : null,
    );
  }

  Widget _buildBody() {
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 40),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ── 날짜 ──────────────────────────────────────────────────────────
          Row(
            children: [
              Icon(Icons.access_time_rounded,
                  size: 13, color: Colors.grey.shade400),
              const SizedBox(width: 4),
              Text(
                _formatDate(widget.createdAt),
                style: TextStyle(fontSize: 12, color: Colors.grey.shade500),
              ),
            ],
          ),
          const SizedBox(height: 16),

          // ── 후기 텍스트 ───────────────────────────────────────────────────
          if (_isEditing)
            TextField(
              controller: _textCtrl,
              maxLines: null,
              minLines: 5,
              style: const TextStyle(fontSize: 15, color: kTextDark, height: 1.7),
              decoration: InputDecoration(
                hintText: '임장 내용을 입력하세요',
                hintStyle: TextStyle(color: Colors.grey.shade400),
                contentPadding: const EdgeInsets.all(14),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                  borderSide: BorderSide(color: kBorderColor),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                  borderSide: const BorderSide(color: kPrimary),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                  borderSide: BorderSide(color: kBorderColor),
                ),
                filled: true,
                fillColor: const Color(0xFFF8FAFC),
              ),
            )
          else
            Text(
              widget.text.isEmpty ? '(내용이 없습니다)' : widget.text,
              style: const TextStyle(
                fontSize: 15,
                color: kTextDark,
                height: 1.75,
              ),
            ),

          const SizedBox(height: 24),

          // ── 사진 그리드 ───────────────────────────────────────────────────
          if (_isEditing)
            _buildEditGrid()
          else if (_currentUrls.isNotEmpty)
            _buildViewGrid(),
        ],
      ),
    );
  }

  // ── 보기 모드 사진 그리드 ─────────────────────────────────────────────────

  Widget _buildViewGrid() {
    return GridView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 3,
        crossAxisSpacing: 3,
        mainAxisSpacing: 3,
        childAspectRatio: 1,
      ),
      itemCount: _currentUrls.length,
      itemBuilder: (_, i) => GestureDetector(
        onTap: () => _openImageViewer(_currentUrls, i),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(6),
          child: CachedNetworkImage(
            imageUrl: _currentUrls[i],
            fit: BoxFit.cover,
            placeholder: (_, __) =>
                Container(color: const Color(0xFFF0F4F8)),
            errorWidget: (_, __, ___) => Container(
              color: const Color(0xFFF0F4F8),
              child: const Icon(Icons.broken_image_outlined,
                  color: Colors.grey, size: 24),
            ),
          ),
        ),
      ),
    );
  }

  // ── 편집 모드 사진 그리드 ─────────────────────────────────────────────────

  Widget _buildEditGrid() {
    final totalExisting = _currentUrls.length;
    final totalNew = _newImages.length;
    final totalItems = totalExisting + totalNew + 1; // +1 = 추가 버튼

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('사진',
            style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: kTextMuted)),
        const SizedBox(height: 8),
        GridView.builder(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: 3,
            crossAxisSpacing: 3,
            mainAxisSpacing: 3,
            childAspectRatio: 1,
          ),
          itemCount: totalItems,
          itemBuilder: (_, i) {
            // 기존 이미지
            if (i < totalExisting) {
              return _EditImageTile(
                child: CachedNetworkImage(
                  imageUrl: _currentUrls[i],
                  fit: BoxFit.cover,
                ),
                onDelete: () => _removeExistingImage(i),
              );
            }
            // 새 이미지
            if (i < totalExisting + totalNew) {
              final ni = i - totalExisting;
              return _EditImageTile(
                child: Image.file(File(_newImages[ni].path),
                    fit: BoxFit.cover),
                onDelete: () => _removeNewImage(ni),
              );
            }
            // 추가 버튼
            return GestureDetector(
              onTap: _pickImages,
              child: Container(
                decoration: BoxDecoration(
                  color: const Color(0xFFF0F4F8),
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(
                      color: kBorderColor, style: BorderStyle.solid),
                ),
                child: const Icon(Icons.add_photo_alternate_outlined,
                    color: kTextMuted, size: 28),
              ),
            );
          },
        ),
      ],
    );
  }

  String _formatDate(DateTime dt) {
    const months = [
      '1월', '2월', '3월', '4월', '5월', '6월',
      '7월', '8월', '9월', '10월', '11월', '12월',
    ];
    final h = dt.hour.toString().padLeft(2, '0');
    final m = dt.minute.toString().padLeft(2, '0');
    return '${dt.year}년 ${months[dt.month - 1]} ${dt.day}일  $h:$m';
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// 편집 모드 사진 타일 (X 버튼 포함)
// ─────────────────────────────────────────────────────────────────────────────

class _EditImageTile extends StatelessWidget {
  const _EditImageTile({required this.child, required this.onDelete});
  final Widget child;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(6),
      child: Stack(
        fit: StackFit.expand,
        children: [
          child,
          Positioned(
            top: 4,
            right: 4,
            child: GestureDetector(
              onTap: onDelete,
              child: Container(
                width: 22,
                height: 22,
                decoration: BoxDecoration(
                  color: Colors.black54,
                  shape: BoxShape.circle,
                ),
                child: const Icon(Icons.close_rounded,
                    color: Colors.white, size: 14),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// 전체화면 사진 뷰어 — 좌우 스와이프 + 핀치줌
// ─────────────────────────────────────────────────────────────────────────────

class _FullscreenViewer extends StatefulWidget {
  const _FullscreenViewer({
    required this.urls,
    required this.initialIndex,
  });

  final List<String> urls;
  final int initialIndex;

  @override
  State<_FullscreenViewer> createState() => _FullscreenViewerState();
}

class _FullscreenViewerState extends State<_FullscreenViewer> {
  late final PageController _pageCtrl;
  late int _current;

  @override
  void initState() {
    super.initState();
    _current = widget.initialIndex;
    _pageCtrl = PageController(initialPage: widget.initialIndex);
  }

  @override
  void dispose() {
    _pageCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.close_rounded, color: Colors.white, size: 26),
          onPressed: () => Navigator.pop(context),
        ),
        actions: [
          if (widget.urls.length > 1)
            Padding(
              padding: const EdgeInsets.only(right: 16),
              child: Center(
                child: Text(
                  '${_current + 1} / ${widget.urls.length}',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ),
        ],
      ),
      body: PageView.builder(
        controller: _pageCtrl,
        itemCount: widget.urls.length,
        onPageChanged: (i) => setState(() => _current = i),
        itemBuilder: (_, i) => InteractiveViewer(
          minScale: 0.5,
          maxScale: 5.0,
          child: Center(
            child: CachedNetworkImage(
              imageUrl: widget.urls[i],
              fit: BoxFit.contain,
              placeholder: (_, __) => const Center(
                child: CircularProgressIndicator(
                    color: Colors.white, strokeWidth: 2),
              ),
              errorWidget: (_, __, ___) => const Icon(
                Icons.broken_image_outlined,
                color: Colors.white54,
                size: 48,
              ),
            ),
          ),
        ),
      ),
      // 하단 점 인디케이터
      bottomNavigationBar: widget.urls.length > 1
          ? Container(
              color: Colors.black,
              padding: const EdgeInsets.only(bottom: 24, top: 12),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: List.generate(widget.urls.length, (i) {
                  return AnimatedContainer(
                    duration: const Duration(milliseconds: 200),
                    width: _current == i ? 18 : 6,
                    height: 6,
                    margin: const EdgeInsets.symmetric(horizontal: 3),
                    decoration: BoxDecoration(
                      color: _current == i ? Colors.white : Colors.white38,
                      borderRadius: BorderRadius.circular(3),
                    ),
                  );
                }),
              ),
            )
          : null,
    );
  }
}
