import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:image_picker/image_picker.dart';

import '../main.dart'
    show kPrimary, kSurface, kBackground, kTextDark, kTextMuted, kBorderColor;
import '../services/imjang_service.dart';

// ── 카카오 로컬 API 설정 ────────────────────────────────────────────────────────
// map_screen.dart와 동일한 REST API 키 사용
const _kKakaoRestApiKey = '58af62d9bd084e0ba7c2fa105414160c';
const _kKakaoSearchUrl = 'https://dapi.kakao.com/v2/local/search/keyword.json';

/// 임장 노트 작성 화면.
///
/// 제목, 위치(카카오 키워드 검색), 후기 텍스트, 사진 첨부를 입력받아
/// [ImjangService.saveImjangRecord]를 통해 Firestore + Storage에 저장합니다.
class WriteImjangScreen extends StatefulWidget {
  const WriteImjangScreen({super.key});

  @override
  State<WriteImjangScreen> createState() => _WriteImjangScreenState();
}

class _WriteImjangScreenState extends State<WriteImjangScreen> {
  final _formKey = GlobalKey<FormState>();
  final _titleCtrl = TextEditingController();
  final _reviewCtrl = TextEditingController();
  final _locationDisplayCtrl = TextEditingController();

  String? _selectedPlaceName;
  String? _selectedAddress;
  double? _selectedLat;
  double? _selectedLng;

  final List<File> _selectedImages = [];
  final _picker = ImagePicker();
  bool _isSaving = false;

  @override
  void dispose() {
    _titleCtrl.dispose();
    _reviewCtrl.dispose();
    _locationDisplayCtrl.dispose();
    super.dispose();
  }

  // ── 카카오 키워드 검색 ──────────────────────────────────────────────────────

  Future<List<_KakaoPlace>> _searchKakao(String query) async {
    if (query.trim().isEmpty) return [];
    try {
      final uri = Uri.parse(
          '$_kKakaoSearchUrl?query=${Uri.encodeComponent(query)}&size=15');
      final res = await http.get(
        uri,
        headers: {'Authorization': 'KakaoAK $_kKakaoRestApiKey'},
      );
      if (res.statusCode != 200) return [];
      final json = jsonDecode(res.body) as Map<String, dynamic>;
      final docs = json['documents'] as List<dynamic>;
      return docs
          .map((d) => _KakaoPlace.fromJson(d as Map<String, dynamic>))
          .toList();
    } catch (_) {
      return [];
    }
  }

  Future<void> _openLocationSearch() async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => _LocationSearchSheet(
        onPlaceSelected: (place) {
          setState(() {
            _selectedPlaceName = place.placeName;
            _selectedAddress = place.addressName;
            _selectedLat = place.lat;
            _selectedLng = place.lng;
            _locationDisplayCtrl.text =
                '${place.placeName}  ${place.addressName}';
          });
        },
        searchKakao: _searchKakao,
      ),
    );
  }

  void _clearLocation() {
    setState(() {
      _selectedPlaceName = null;
      _selectedAddress = null;
      _selectedLat = null;
      _selectedLng = null;
      _locationDisplayCtrl.clear();
    });
  }

  // ── 이미지 선택 ─────────────────────────────────────────────────────────────

  Future<void> _pickImages() async {
    final picked = await _picker.pickMultiImage(imageQuality: 80);
    if (picked.isEmpty) return;
    setState(() {
      for (final xf in picked) {
        if (_selectedImages.length >= 10) break;
        _selectedImages.add(File(xf.path));
      }
    });
  }

  void _removeImage(int index) {
    setState(() => _selectedImages.removeAt(index));
  }

  // ── 저장 ────────────────────────────────────────────────────────────────────

  String _deriveRegion(String address) {
    if (address.contains('서울')) return '서울';
    if (address.contains('경기') || address.contains('인천')) return '경기/인천';
    if (address.contains('부산') || address.contains('경남')) return '부산/경남';
    return '지방';
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    if (_selectedLat == null || _selectedLng == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('위치를 선택해 주세요.'),
          margin: EdgeInsets.all(16),
        ),
      );
      return;
    }

    setState(() => _isSaving = true);
    try {
      await ImjangService().saveImjangRecord(
        title: _titleCtrl.text.trim(),
        address: _selectedAddress!,
        region: _deriveRegion(_selectedAddress!),
        latitude: _selectedLat!,
        longitude: _selectedLng!,
        review: _reviewCtrl.text.trim(),
        mediaFiles: _selectedImages,
      );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('임장 노트가 저장되었습니다.'),
            margin: EdgeInsets.all(16),
          ),
        );
        Navigator.pop(context, true);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('저장 실패: $e'),
            margin: const EdgeInsets.all(16),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  // ── UI ──────────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: kBackground,
      appBar: AppBar(
        title: const Text('임장 노트 작성'),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: TextButton(
              onPressed: _isSaving ? null : _save,
              child: Text(
                '완료',
                style: TextStyle(
                  fontWeight: FontWeight.w700,
                  fontSize: 15,
                  color: _isSaving ? Colors.grey : kPrimary,
                ),
              ),
            ),
          ),
        ],
      ),
      body: Stack(
        children: [
          Form(
            key: _formKey,
            child: ListView(
              padding: const EdgeInsets.fromLTRB(20, 20, 20, 60),
              children: [
                _buildSectionLabel('제목'),
                const SizedBox(height: 8),
                _buildTitleField(),
                const SizedBox(height: 24),
                _buildSectionLabel('위치'),
                const SizedBox(height: 8),
                _buildLocationField(),
                const SizedBox(height: 24),
                _buildSectionLabel('내용'),
                const SizedBox(height: 8),
                _buildReviewField(),
                const SizedBox(height: 24),
                _buildSectionLabel('사진 첨부 (최대 10장)'),
                const SizedBox(height: 8),
                _buildImagePicker(),
              ],
            ),
          ),
          if (_isSaving)
            Container(
              color: Colors.black45,
              child: const Center(
                child: CircularProgressIndicator(color: Colors.white),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildSectionLabel(String label) {
    return Text(
      label,
      style: const TextStyle(
        fontSize: 12,
        fontWeight: FontWeight.w700,
        color: kTextMuted,
        letterSpacing: 0.4,
      ),
    );
  }

  Widget _buildTitleField() {
    return TextFormField(
      controller: _titleCtrl,
      maxLength: 50,
      decoration: const InputDecoration(
        hintText: '예: 분당 신축 아파트 현장 방문',
        counterText: '',
      ),
      validator: (v) =>
          (v == null || v.trim().isEmpty) ? '제목을 입력해 주세요.' : null,
    );
  }

  Widget _buildLocationField() {
    return TextFormField(
      controller: _locationDisplayCtrl,
      readOnly: true,
      onTap: _openLocationSearch,
      decoration: InputDecoration(
        hintText: '지역, 건물명, 도로명으로 검색',
        prefixIcon: const Icon(Icons.search_rounded, size: 20),
        suffixIcon: _selectedPlaceName != null
            ? IconButton(
                icon: const Icon(Icons.close_rounded, size: 18),
                onPressed: _clearLocation,
              )
            : null,
      ),
    );
  }

  Widget _buildReviewField() {
    return TextFormField(
      controller: _reviewCtrl,
      maxLines: 8,
      maxLength: 2000,
      keyboardType: TextInputType.multiline,
      decoration: const InputDecoration(
        hintText: '현장 방문 후기, 장단점, 특이사항 등을 자유롭게 기록하세요.',
        alignLabelWithHint: true,
      ),
      validator: (v) =>
          (v == null || v.trim().isEmpty) ? '내용을 입력해 주세요.' : null,
    );
  }

  Widget _buildImagePicker() {
    final canAdd = _selectedImages.length < 10;
    return SizedBox(
      height: 88,
      child: ListView(
        scrollDirection: Axis.horizontal,
        children: [
          // 추가 버튼
          GestureDetector(
            onTap: canAdd ? _pickImages : null,
            child: Container(
              width: 80,
              height: 80,
              margin: const EdgeInsets.only(right: 8),
              decoration: BoxDecoration(
                color: kSurface,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color: canAdd ? kPrimary.withValues(alpha: 0.35) : kBorderColor,
                ),
              ),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(
                    Icons.add_photo_alternate_outlined,
                    size: 26,
                    color: canAdd ? kPrimary : Colors.grey.shade300,
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '${_selectedImages.length}/10',
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      color: canAdd ? kPrimary : Colors.grey.shade400,
                    ),
                  ),
                ],
              ),
            ),
          ),
          // 선택된 이미지 썸네일
          ..._selectedImages.asMap().entries.map((entry) {
            final idx = entry.key;
            final file = entry.value;
            return Stack(
              clipBehavior: Clip.none,
              children: [
                Container(
                  width: 80,
                  height: 80,
                  margin: const EdgeInsets.only(right: 8),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(12),
                    image: DecorationImage(
                      image: FileImage(file),
                      fit: BoxFit.cover,
                    ),
                  ),
                ),
                Positioned(
                  top: -4,
                  right: 4,
                  child: GestureDetector(
                    onTap: () => _removeImage(idx),
                    child: Container(
                      width: 20,
                      height: 20,
                      decoration: const BoxDecoration(
                        color: Colors.black54,
                        shape: BoxShape.circle,
                      ),
                      child: const Icon(
                        Icons.close_rounded,
                        size: 13,
                        color: Colors.white,
                      ),
                    ),
                  ),
                ),
              ],
            );
          }),
        ],
      ),
    );
  }
}

// ── 카카오 장소 모델 ────────────────────────────────────────────────────────────

class _KakaoPlace {
  final String placeName;
  final String addressName;
  final double lat;
  final double lng;

  const _KakaoPlace({
    required this.placeName,
    required this.addressName,
    required this.lat,
    required this.lng,
  });

  factory _KakaoPlace.fromJson(Map<String, dynamic> json) {
    final roadAddr = json['road_address_name'] as String? ?? '';
    return _KakaoPlace(
      placeName: json['place_name'] as String? ?? '',
      addressName: roadAddr.isNotEmpty
          ? roadAddr
          : json['address_name'] as String? ?? '',
      lat: double.tryParse(json['y'] as String? ?? '') ?? 0.0,
      lng: double.tryParse(json['x'] as String? ?? '') ?? 0.0,
    );
  }
}

// ── 위치 검색 바텀시트 ──────────────────────────────────────────────────────────

class _LocationSearchSheet extends StatefulWidget {
  const _LocationSearchSheet({
    required this.onPlaceSelected,
    required this.searchKakao,
  });

  final void Function(_KakaoPlace place) onPlaceSelected;
  final Future<List<_KakaoPlace>> Function(String query) searchKakao;

  @override
  State<_LocationSearchSheet> createState() => _LocationSearchSheetState();
}

class _LocationSearchSheetState extends State<_LocationSearchSheet> {
  final _ctrl = TextEditingController();
  List<_KakaoPlace> _results = [];
  bool _isLoading = false;

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  Future<void> _search(String q) async {
    if (q.trim().isEmpty) {
      setState(() => _results = []);
      return;
    }
    setState(() => _isLoading = true);
    final places = await widget.searchKakao(q);
    if (mounted) {
      setState(() {
        _results = places;
        _isLoading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding:
          EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: SizedBox(
        height: MediaQuery.of(context).size.height * 0.75,
        child: Column(
          children: [
            const SizedBox(height: 16),
            Container(
              width: 36,
              height: 4,
              decoration: BoxDecoration(
                color: Colors.grey.shade300,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(height: 16),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: TextField(
                controller: _ctrl,
                autofocus: true,
                decoration: InputDecoration(
                  hintText: '지역, 건물명, 도로명으로 검색',
                  prefixIcon: const Icon(Icons.search_rounded, size: 20),
                  suffixIcon: _ctrl.text.isNotEmpty
                      ? IconButton(
                          icon: const Icon(Icons.close_rounded, size: 18),
                          onPressed: () {
                            _ctrl.clear();
                            setState(() => _results = []);
                          },
                        )
                      : null,
                ),
                onChanged: _search,
              ),
            ),
            const SizedBox(height: 8),
            Expanded(
              child: _isLoading
                  ? const Center(child: CircularProgressIndicator())
                  : _results.isEmpty
                      ? Center(
                          child: Text(
                            _ctrl.text.isEmpty
                                ? '검색어를 입력하세요.'
                                : '검색 결과가 없습니다.',
                            style: const TextStyle(color: Colors.grey),
                          ),
                        )
                      : ListView.separated(
                          itemCount: _results.length,
                          separatorBuilder: (ctx, i) =>
                              const Divider(height: 1),
                          itemBuilder: (context, i) {
                            final place = _results[i];
                            return ListTile(
                              leading: const Icon(
                                Icons.location_on_outlined,
                                color: kPrimary,
                              ),
                              title: Text(
                                place.placeName,
                                style: const TextStyle(
                                  fontSize: 14,
                                  fontWeight: FontWeight.w600,
                                  color: kTextDark,
                                ),
                              ),
                              subtitle: Text(
                                place.addressName,
                                style: const TextStyle(
                                  fontSize: 12,
                                  color: kTextMuted,
                                ),
                              ),
                              onTap: () {
                                widget.onPlaceSelected(place);
                                Navigator.pop(context);
                              },
                            );
                          },
                        ),
            ),
          ],
        ),
      ),
    );
  }
}
