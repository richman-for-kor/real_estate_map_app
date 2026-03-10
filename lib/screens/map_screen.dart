import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter/material.dart';
import 'package:flutter_naver_map/flutter_naver_map.dart';
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;
import 'package:image_picker/image_picker.dart';
import 'package:permission_handler/permission_handler.dart'
    show openAppSettings;
import '../main.dart'
    show
        kPrimary,
        kSecondary,
        kSurface,
        kTextDark,
        kTextMuted,
        kBorderColor;
import 'package:cached_network_image/cached_network_image.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import '../services/house_log_service.dart';
import '../services/imjang_service.dart';
import '../services/public_data_service.dart';
import '../services/apartment_repository.dart';
import '../services/favorite_service.dart';
import '../services/recent_view_service.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'imjang_note_detail_screen.dart';

// ─── 카카오 로컬 API (키워드 장소 검색) 설정 ───────────────────────────────────
// ⚠️  아래 키를 카카오 디벨로퍼스(developers.kakao.com)에서 발급받은
//     [REST API 키]로 교체한 뒤 flutter run 하세요.
const _kKakaoSearchUrl = 'https://dapi.kakao.com/v2/local/search/keyword.json';

// ─── 색상 상수 ─────────────────────────────────────────────────────────────────
const _kPageBg = Color(0xFFF2F2F7);
const _kCardBg = Colors.white;


// ─────────────────────────────────────────────────────────────────────────────
// MapScreen
// ─────────────────────────────────────────────────────────────────────────────

// ─── 아파트 단지명 정규화 (파일 레벨 — MapScreen + PropertyInfoSheet 공용) ────
/// 법정동 접두사·괄호·공백·차/단지 suffix 제거, LG↔엘지 통합.
String _normalizeAptName(String name) {
  var n = name;
  for (final prefix in const [
    '정자', '구미', '분당', '수내', '서현', '이매', '판교',
    '야탑', '금곡', '중앙', '보평', '장안', '율동', '동판교',
  ]) {
    if (n.startsWith(prefix)) {
      n = n.substring(prefix.length);
      break;
    }
  }
  n = n.replaceAll(RegExp(r'[\s()]'), '');
  n = n.replaceAll(RegExp(r'(\d+)(차|단지)'), r'\1');
  n = n.replaceAll('LG', '엘지').replaceAll('lg', '엘지');
  return n;
}

/// 정규화된 두 이름이 minLen자 이상의 공통 부분 문자열을 공유하는지 확인.
bool _sharesCoreSubstring(String a, String b, {int minLen = 3}) {
  if (a.length < minLen || b.length < minLen) return false;
  for (int start = 0; start <= a.length - minLen; start++) {
    for (int len = a.length - start; len >= minLen; len--) {
      if (b.contains(a.substring(start, start + len))) return true;
    }
  }
  return false;
}

/// trade records 중 kaptName과 가장 잘 매칭되는 complexName 반환.
String? _resolveApiName(List<AptTradeRecord> records, String kaptName) {
  if (records.isEmpty) return null;
  // 1. 정확 일치
  for (final r in records) {
    if (r.complexName.trim() == kaptName) return r.complexName.trim();
  }
  // 2. contains 일치
  for (final r in records) {
    final name = r.complexName.trim();
    if (name.contains(kaptName) || kaptName.contains(name)) return name;
  }
  // 3. 정규화 후 공통 핵심어
  final normKapt = _normalizeAptName(kaptName);
  for (final r in records) {
    final normName = _normalizeAptName(r.complexName.trim());
    if (normName == normKapt ||
        normName.contains(normKapt) ||
        normKapt.contains(normName) ||
        _sharesCoreSubstring(normKapt, normName)) {
      return r.complexName.trim();
    }
  }
  return null;
}

typedef _MapJumpTarget = ({double lat, double lng});

class MapScreen extends StatefulWidget {
  const MapScreen({super.key, this.jumpTarget});

  /// 홈 탭에서 지역 카드를 탭할 때 지도 이동 좌표를 전달하는 notifier
  final ValueNotifier<_MapJumpTarget?>? jumpTarget;

  @override
  State<MapScreen> createState() => _MapScreenState();
}

class _MapScreenState extends State<MapScreen> {
  NaverMapController? _mapController;
  _MapJumpTarget? _pendingJump; // mapController 준비 전 요청된 이동 대상
  final _searchController = TextEditingController();

  // 검색 상태 관리
  Timer? _debounce;
  bool _isSearching = false;
  bool _showDropdown = false;
  List<dynamic> _searchResults = [];

  bool _isLocationLoading = false;
  bool _isMarkersLoading = false; // 초기 로딩 시에만 표시

  // ── 뷰포트 기반 마커 상태 ──────────────────────────────────────────────────
  /// 이미 API/Firestore 에서 데이터를 가져온 법정동 코드 집합.
  /// 마커가 뷰포트 밖으로 사라지면 해당 코드도 제거하여 복귀 시 재로드를 허용.
  final Set<String> _loadedBjdCodes = {};
  /// kaptCode → 해당 마커가 속한 bjdCode (마커 제거 시 _loadedBjdCodes 정리용).
  final Map<String, String> _kaptCodeToBjdCode = {};
  /// 그리드 키("lat_idx_lng_idx") → bjdCode 캐시 (역지오코딩 중복 API 호출 방지).
  final Map<String, String?> _gridBjdCache = {};
  /// lawdCd → 최근 3개월 실거래가 Future 캐시 (빠른 마커 아이콘용).
  final Map<String, Future<Map<String, _MarkerPrice>>> _fastPriceMapCache = {};
  /// lawdCd → 이전 4~12개월 실거래가 Future 캐시 (미매칭 단지 보완용).
  final Map<String, Future<Map<String, _MarkerPrice>>> _supplementalPriceMapCache = {};
  /// 렌더링 세대(generation) 카운터 — 이전 렌더 요청을 취소하는 데 사용.
  int _renderGeneration = 0;
  /// 앱 첫 로드 여부 — true일 때만 로딩 배지를 표시.
  bool _isInitialLoad = true;

  NMarker? _searchMarker;
  // kaptCode → NMarker (뷰포트 기반 관리)
  final Map<String, NMarker> _aptMarkerMap = {};

  static const _kInitialPosition = NCameraPosition(
    target: NLatLng(37.3620, 127.1070), // 분당 미금역 인근
    zoom: 14,
    bearing: 0,
    tilt: 0,
  );

  static const _kMapOptions = NaverMapViewOptions(
    initialCameraPosition: _kInitialPosition,
    mapType: NMapType.basic,
    rotationGesturesEnable: true,
    scrollGesturesEnable: true,
    tiltGesturesEnable: false,
    zoomGesturesEnable: true,
    stopGesturesEnable: true,
    locationButtonEnable: false,
    scaleBarEnable: true,
    consumeSymbolTapEvents: false,
    logoAlign: NLogoAlign.leftBottom,
  );

  @override
  void initState() {
    super.initState();
    widget.jumpTarget?.addListener(_onJumpTarget);
  }

  @override
  void dispose() {
    widget.jumpTarget?.removeListener(_onJumpTarget);
    _debounce?.cancel();
    _searchController.dispose();
    super.dispose();
  }

  void _onJumpTarget() {
    final t = widget.jumpTarget?.value;
    if (t == null) return;
    if (_mapController != null) {
      _moveCameraTo(t.lat, t.lng);
    } else {
      _pendingJump = t;
    }
  }

  void _moveCameraTo(double lat, double lng) {
    _mapController?.updateCamera(
      NCameraUpdate.scrollAndZoomTo(
        target: NLatLng(lat, lng),
        zoom: 14,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Stack(
        fit: StackFit.expand,
        children: [
          Positioned.fill(
            child: NaverMap(
              options: _kMapOptions,
              onMapReady: _onMapReady,
              onMapTapped: _onMapTapped,
              onCameraIdle: _onCameraIdle,
            ),
          ),

          // ── 검색창 및 자동완성 드롭다운 ──
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: SafeArea(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                child: Column(
                  children: [
                    _buildSearchBar(),
                    if (_showDropdown && _searchResults.isNotEmpty)
                      _buildDropdownList(),
                  ],
                ),
              ),
            ),
          ),

          Positioned(
            bottom: MediaQuery.of(context).padding.bottom + 24,
            right: 16,
            child: _buildMyLocationButton(),
          ),

          // ── 마커 데이터 로딩 배지 ──
          if (_isMarkersLoading)
            Positioned(
              top: MediaQuery.of(context).padding.top + 72,
              left: 0,
              right: 0,
              child: Center(
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 7,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.93),
                    borderRadius: BorderRadius.circular(20),
                    boxShadow: const [
                      BoxShadow(color: Colors.black12, blurRadius: 8),
                    ],
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      SizedBox(
                        width: 13,
                        height: 13,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: kPrimary,
                        ),
                      ),
                      const SizedBox(width: 8),
                      const Text(
                        '단지 정보 불러오는 중...',
                        style: TextStyle(fontSize: 12, color: kTextMuted),
                      ),
                    ],
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  // ── NaverMap Callbacks ───────────────────────────────────────────────────

  Future<void> _onMapReady(NaverMapController controller) async {
    _mapController = controller;

    // 홈 탭 지역 카드에서 이동 요청이 있으면 해당 위치로 이동
    // → updateCamera 완료 후 _onCameraIdle이 자동으로 발화하여 마커를 로드함
    if (_pendingJump != null) {
      _moveCameraTo(_pendingJump!.lat, _pendingJump!.lng);
      _pendingJump = null;
      return;
    }

    // GPS 권한이 있으면 현재 위치로 카메라 이동
    bool moved = false;
    try {
      final permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.whileInUse ||
          permission == LocationPermission.always) {
        final pos = await Geolocator.getCurrentPosition(
          locationSettings: const LocationSettings(
            accuracy: LocationAccuracy.high,
          ),
        ).timeout(const Duration(seconds: 5));

        if (!mounted) return;
        controller.setLocationTrackingMode(NLocationTrackingMode.noFollow);
        await _customizeLocationOverlay();
        await controller.updateCamera(
          NCameraUpdate.scrollAndZoomTo(
            target: NLatLng(pos.latitude, pos.longitude),
            zoom: 14,
          ),
        );
        // updateCamera 완료 → _onCameraIdle 자동 발화
        moved = true;
      }
    } catch (e) {
      debugPrint('[MapScreen] 초기 현재 위치 이동 실패: $e');
    }

    // 카메라를 이동하지 않은 경우 _onCameraIdle이 자동으로 발화하지 않을 수 있으므로 직접 호출
    if (!moved && mounted) _onCameraIdle();
  }

  Future<void> _onCameraIdle() async {
    if (_mapController == null) return;
    final position = await _mapController!.getCameraPosition();
    final zoom = position.zoom;
    debugPrint('[CameraIdle] zoom=${zoom.toStringAsFixed(1)}');

    // 줌 12 미만 → 마커 전체 제거
    if (zoom < 12) {
      await _clearAllAptMarkers();
      return;
    }

    // ── NaverMap 정확한 화면 Bounds 취득 ───────────────────────────────────
    NLatLngBounds contentBounds;
    try {
      contentBounds = await _mapController!.getContentBounds();
    } catch (e) {
      debugPrint('[CameraIdle] getContentBounds 실패: $e');
      return;
    }

    // 렌더/삭제 기준: 화면 bounds + 0.01° 버퍼 (가장자리 깜빡임 방지)
    const buf = 0.01;
    final renderBounds = NLatLngBounds(
      southWest: NLatLng(
        contentBounds.southWest.latitude - buf,
        contentBounds.southWest.longitude - buf,
      ),
      northEast: NLatLng(
        contentBounds.northEast.latitude + buf,
        contentBounds.northEast.longitude + buf,
      ),
    );

    // ── 화면 밖 마커 정확히 제거 ───────────────────────────────────────────
    await _removeOutOfBoundsMarkers(renderBounds);

    // ── 4×4 그리드 샘플링 — 화면 구석 법정동 누락 방지 ────────────────────
    final sw = contentBounds.southWest;
    final ne = contentBounds.northEast;
    const divisions = 3; // 0~3 → 4×4 = 16 포인트
    final newBjdCodes = <String>{};
    for (var r = 0; r <= divisions; r++) {
      for (var c = 0; c <= divisions; c++) {
        if (!mounted) return;
        final lat = sw.latitude + (ne.latitude - sw.latitude) * r / divisions;
        final lng = sw.longitude + (ne.longitude - sw.longitude) * c / divisions;
        final bjdCode = await _getCachedBjdCode(lat, lng);
        if (bjdCode != null && !_loadedBjdCodes.contains(bjdCode)) {
          newBjdCodes.add(bjdCode);
        }
      }
    }

    if (newBjdCodes.isEmpty) return;

    // ── generation 카운터 증가 → 이전 렌더 작업 무효화 ───────────────────────
    final generation = ++_renderGeneration;

    // 초기 로드일 때만 로딩 배지 표시
    final showLoading = _isInitialLoad;
    if (showLoading && mounted) setState(() => _isMarkersLoading = true);

    try {
      for (final bjdCode in newBjdCodes) {
        if (!mounted || generation != _renderGeneration) return;
        // 선점: 중복 요청 방지 (실패/취소 시 _fetchAndRenderBjdCode에서 rollback)
        _loadedBjdCodes.add(bjdCode);
        await _fetchAndRenderBjdCode(bjdCode, generation, renderBounds);
      }
    } finally {
      if (showLoading) {
        _isInitialLoad = false;
        if (mounted) setState(() => _isMarkersLoading = false);
      }
    }
  }

  // ── 뷰포트 밖 마커 정확히 제거 — getContentBounds() 기반 ──────────────────
  // 임의의 수학 공식 없이 실제 화면 bounds를 기준으로 판단.
  // deleteOverlay를 await(Future.wait 배치)하여 플랫폼 채널 호출을 완료 보장.
  Future<void> _removeOutOfBoundsMarkers(NLatLngBounds removeBounds) async {
    if (_aptMarkerMap.isEmpty || _mapController == null) return;

    // 제거 대상 수집 (id → NOverlayInfo)
    final toRemove = <String, NOverlayInfo>{};
    for (final entry in _aptMarkerMap.entries) {
      if (!_boundsContains(removeBounds, entry.value.position)) {
        toRemove[entry.key] = entry.value.info;
      }
    }
    if (toRemove.isEmpty) return;

    // 상태를 먼저 동기적으로 갱신 → 동시 호출 시 중복 삭제 방지
    for (final id in toRemove.keys) {
      _aptMarkerMap.remove(id);
      _kaptCodeToBjdCode.remove(id);
    }

    // 해당 bjdCode의 마커가 모두 사라졌으면 _loadedBjdCodes에서 제거
    // → 사용자가 다시 돌아오면 Firestore 캐시에서 빠르게 재로드
    final remaining = _kaptCodeToBjdCode.values.toSet();
    _loadedBjdCodes.removeWhere((bjd) => !remaining.contains(bjd));

    // 플랫폼 채널 삭제를 배치로 await → 실제 지도에서 마커가 확실히 사라짐
    await Future.wait(
      toRemove.values.map((info) => _mapController!.deleteOverlay(info)),
    );

    debugPrint(
      '[MapScreen] 마커 제거 — ${toRemove.length}개 삭제, 남은 ${_aptMarkerMap.length}개',
    );
  }

  /// NLatLngBounds 내부에 점이 포함되는지 확인.
  bool _boundsContains(NLatLngBounds b, NLatLng p) =>
      p.latitude >= b.southWest.latitude &&
      p.latitude <= b.northEast.latitude &&
      p.longitude >= b.southWest.longitude &&
      p.longitude <= b.northEast.longitude;

  // ── 전체 아파트 마커 제거 (줌 아웃 시) ───────────────────────────────────
  Future<void> _clearAllAptMarkers() async {
    if (_aptMarkerMap.isEmpty || _mapController == null) return;
    final infos = _aptMarkerMap.values.map((m) => m.info).toList();
    _aptMarkerMap.clear();
    _kaptCodeToBjdCode.clear();
    _loadedBjdCodes.clear();
    await Future.wait(infos.map((info) => _mapController!.deleteOverlay(info)));
    debugPrint('[MapScreen] 줌 아웃 — 전체 마커 제거');
  }

  // ── 그리드 기반 좌표 캐시 (역지오코딩 중복 API 호출 방지) ─────────────────
  // 0.025° lat ≈ 2.8km, 0.035° lng ≈ 3.1km 격자로 캐싱
  String _gridKey(double lat, double lng) =>
      '${(lat / 0.025).floor()}_${(lng / 0.035).floor()}';

  Future<String?> _getCachedBjdCode(double lat, double lng) async {
    final key = _gridKey(lat, lng);
    if (_gridBjdCache.containsKey(key)) return _gridBjdCache[key];
    final bjdCode = await _getBjdCodeFromCoords(lat, lng);
    _gridBjdCache[key] = bjdCode;
    return bjdCode;
  }

  // ── 카카오 로컬 API — 역지오코딩 (좌표 → 법정동 코드) ─────────────────────────
  Future<String?> _getBjdCodeFromCoords(double lat, double lng) async {
    try {
      final kakaoKey = dotenv.env['KAKAO_REST_API_KEY'];
      if (kakaoKey == null || kakaoKey.isEmpty) {
        debugPrint('[Kakao Geo] KAKAO_REST_API_KEY 없음 — 역지오코딩 스킵');
        return null;
      }
      final uri = Uri.parse(
        'https://dapi.kakao.com/v2/local/geo/coord2regioncode.json'
        '?x=$lng&y=$lat',
      );
      final res = await http
          .get(uri, headers: {'Authorization': 'KakaoAK $kakaoKey'})
          .timeout(const Duration(seconds: 5));
      if (res.statusCode != 200) {
        debugPrint('[Kakao Geo Error ${res.statusCode}] ${res.body}');
        return null;
      }
      final documents =
          (jsonDecode(res.body) as Map<String, dynamic>)['documents']
              as List<dynamic>;
      final bjd = documents.firstWhere(
        (d) => d['region_type'] == 'B',
        orElse: () => null,
      );
      return bjd?['code'] as String?;
    } catch (e) {
      debugPrint('[Kakao Geo Exception] $e');
      return null;
    }
  }

  // ── 말풍선 마커 아이콘 생성 ──────────────────────────────────────────────
  Future<NOverlayImage?> _buildMarkerIcon(
    ApartmentInfo apt, {
    String priceLabel = '',
    String pyeongLabel = '',
  }) async {
    try {
      return await NOverlayImage.fromWidget(
        context: context,
        size: const Size(76, 60),
        widget: _AptPriceBubble(
          priceLabel: priceLabel,
          pyeongLabel: pyeongLabel,
        ),
      );
    } catch (e) {
      debugPrint('[MapScreen] 마커 아이콘 생성 실패 (${apt.kaptName}): $e');
      return null; // null → NaverMap 기본 마커 사용
    }
  }

  // ── Phase-1: 아파트 목록만 즉시 렌더링 → Phase-2: 백그라운드 가격 업데이트 ──
  //
  // 이전 방식: Future.wait([apts, priceMap]) → 실거래가 완료 전까지 마커 0개
  // 새 방식  : apts 완료 즉시 기본 마커 표시 → 가격 로드 완료 후 아이콘 교체
  Future<void> _fetchAndRenderBjdCode(
    String bjdCode,
    int generation,
    NLatLngBounds renderBounds,
  ) async {
    if (!mounted || _mapController == null) {
      _loadedBjdCodes.remove(bjdCode); // 롤백
      return;
    }
    final lawdCd = bjdCode.length >= 5 ? bjdCode.substring(0, 5) : bjdCode;

    // ── Phase 1: 단지 목록 로드 → 기본 마커 즉시 표시 ──────────────────────
    List<ApartmentInfo> apts;
    try {
      apts = await ApartmentRepository.instance.getApartmentsByBjdCode(bjdCode);
    } catch (e) {
      debugPrint('[MapScreen] 아파트 목록 로드 실패 bjdCode=$bjdCode: $e');
      _loadedBjdCodes.remove(bjdCode); // 롤백
      return;
    }

    // generation 이 바뀌었으면 마커를 그리지 않고 선점도 해제 (롤백)
    if (!mounted || generation != _renderGeneration) {
      _loadedBjdCodes.remove(bjdCode);
      return;
    }

    await _addBasicMarkers(apts, bjdCode, lawdCd, generation, renderBounds);

    // 마커가 실제로 하나도 추가되지 않았으면 선점 해제 → 재시도 허용
    if (!_kaptCodeToBjdCode.containsValue(bjdCode)) {
      _loadedBjdCodes.remove(bjdCode);
      return;
    }

    if (!mounted || generation != _renderGeneration) return;

    // ── Phase 2: 실거래가 백그라운드 로드 → 마커 아이콘 교체 ─────────────
    // fire-and-forget: await 하지 않아 _onCameraIdle을 블로킹하지 않음
    _loadAndApplyPrices(apts, lawdCd, generation);
  }

  // ── Phase 1: 기본 마커 일괄 추가 (가격 아이콘 없이 빠르게) ────────────────
  // NOverlayImage.fromWidget을 사용하지 않아 즉각 렌더링 가능.
  // renderBounds 범위 밖 좌표는 추가하지 않아 화면 밖 렌더링 방지.
  Future<void> _addBasicMarkers(
    List<ApartmentInfo> apts,
    String bjdCode,
    String lawdCd,
    int generation,
    NLatLngBounds renderBounds,
  ) async {
    if (!mounted || _mapController == null) return;

    final newMarkers = <NMarker>[];
    for (final apt in apts.where((a) => a.hasValidCoords)) {
      if (!mounted || generation != _renderGeneration) return;
      if (_aptMarkerMap.containsKey(apt.kaptCode)) continue; // Diffing

      final pos = NLatLng(apt.lat, apt.lng);

      // 화면(+버퍼) 밖이면 마커 추가 생략 → 과도한 렌더링 방지
      if (!_boundsContains(renderBounds, pos)) continue;

      final marker = NMarker(id: apt.kaptCode, position: pos);

      // 기본 마커: 캡션(단지명)만, 커스텀 아이콘 없음 → 즉시 표시 가능
      marker.setCaption(
        NOverlayCaption(
          text: apt.kaptName,
          textSize: 10,
          color: kTextMuted,
          haloColor: Colors.white,
        ),
      );
      marker.setOnTapListener((_) {
        _showPropertyInfoSheet(pos, apt.kaptName, lawdCd: lawdCd, apt: apt);
        return true;
      });

      newMarkers.add(marker);
    }

    if (!mounted || _mapController == null || generation != _renderGeneration) return;
    if (newMarkers.isEmpty) {
      debugPrint('[MapScreen] bjdCode=$bjdCode — 신규 마커 없음');
      return;
    }

    await _mapController!.addOverlayAll(newMarkers.toSet());
    for (final m in newMarkers) {
      _aptMarkerMap[m.info.id] = m;
      _kaptCodeToBjdCode[m.info.id] = bjdCode;
    }
    debugPrint('[MapScreen] bjdCode=$bjdCode 기본 마커 ${newMarkers.length}개 즉시 표시');
  }

  // ── Phase 2A: 최근 3개월 가격 → 즉시 아이콘 / Phase 2B: 나머지 9개월 백그라운드 ──
  Future<void> _loadAndApplyPrices(
    List<ApartmentInfo> apts,
    String lawdCd,
    int generation,
  ) async {
    // Phase 2A: 최근 3개월 (빠름, ~3 API 호출)
    final fastMap = await _getFastPriceMap(lawdCd);
    if (!mounted || generation != _renderGeneration) return;

    if (fastMap.isNotEmpty) {
      await _applyPriceIcons(apts, fastMap, lawdCd, generation);
      if (!mounted || generation != _renderGeneration) return;
    }

    // Phase 2B: 이전 9개월 백그라운드 — 아직 가격 없는 단지만 보완
    final unmatched = apts
        .where((a) =>
            _aptMarkerMap.containsKey(a.kaptCode) &&
            _findPriceMatch(fastMap, a.kaptName.trim()) == null)
        .toList();
    if (unmatched.isNotEmpty) {
      _loadSupplementalPrices(unmatched, lawdCd, generation);
    }
  }

  /// 보완 가격(4~12개월)을 백그라운드 로드 → 미매칭 단지 아이콘 업데이트.
  Future<void> _loadSupplementalPrices(
    List<ApartmentInfo> unmatched,
    String lawdCd,
    int generation,
  ) async {
    final suppMap = await _getSupplementalPriceMap(lawdCd);
    if (!mounted || generation != _renderGeneration || suppMap.isEmpty) return;
    await _applyPriceIcons(unmatched, suppMap, lawdCd, generation);
    debugPrint('[MapScreen] $lawdCd 보완 가격 ${unmatched.length}개 대상 업데이트');
  }

  /// [priceMap] 기준으로 [apts] 매칭 마커 아이콘을 말풍선으로 교체. 10개씩 병렬.
  Future<void> _applyPriceIcons(
    List<ApartmentInfo> apts,
    Map<String, _MarkerPrice> priceMap,
    String lawdCd,
    int generation,
  ) async {
    final matched = <({ApartmentInfo apt, _MarkerPrice mp, String? apiName})>[];
    for (final apt in apts) {
      final mp = _findPriceMatch(priceMap, apt.kaptName.trim());
      if (mp != null) {
        matched.add((
          apt: apt,
          mp: mp,
          apiName: _findMatchedKey(priceMap, apt.kaptName.trim()),
        ));
      }
    }
    if (matched.isEmpty) return;

    const chunkSize = 10;
    for (var i = 0; i < matched.length; i += chunkSize) {
      if (!mounted || generation != _renderGeneration) return;
      final chunk = matched.sublist(i, (i + chunkSize).clamp(0, matched.length));
      await Future.wait(chunk.map((item) async {
        if (!mounted || generation != _renderGeneration) return;
        final marker = _aptMarkerMap[item.apt.kaptCode];
        if (marker == null) return;

        final icon = await _buildMarkerIcon(
          item.apt,
          priceLabel: item.mp.priceLabel,
          pyeongLabel: item.mp.pyeongLabel,
        );
        if (!mounted || generation != _renderGeneration || icon == null) return;

        marker.setIcon(icon);
        marker.setAnchor(const NPoint(0.5, 1.0));

        final pos = marker.position;
        final lcd = item.apt.bjdCode.length >= 5
            ? item.apt.bjdCode.substring(0, 5)
            : item.apt.bjdCode;
        marker.setOnTapListener((_) {
          _showPropertyInfoSheet(
            pos,
            item.apt.kaptName,
            lawdCd: lcd,
            apt: item.apt,
            apiName: item.apiName,
          );
          return true;
        });
      }));
    }
    debugPrint('[MapScreen] $lawdCd 가격 아이콘 ${matched.length}개 교체');
  }

  // ── 단지명 기반 가격 매칭 헬퍼 ────────────────────────────────────────────
  _MarkerPrice? _findPriceMatch(
    Map<String, _MarkerPrice> priceMap,
    String aptName,
  ) {
    if (priceMap.containsKey(aptName)) return priceMap[aptName];
    for (final e in priceMap.entries) {
      if (e.key.contains(aptName) || aptName.contains(e.key)) return e.value;
    }
    final norm = _normalizeAptName(aptName);
    for (final e in priceMap.entries) {
      final normKey = _normalizeAptName(e.key);
      if (normKey == norm ||
          normKey.contains(norm) ||
          norm.contains(normKey) ||
          _sharesCoreSubstring(norm, normKey)) {
        return e.value;
      }
    }
    return null;
  }

  String? _findMatchedKey(
    Map<String, _MarkerPrice> priceMap,
    String aptName,
  ) {
    if (priceMap.containsKey(aptName)) return aptName;
    for (final key in priceMap.keys) {
      if (key.contains(aptName) || aptName.contains(key)) return key;
    }
    final norm = _normalizeAptName(aptName);
    for (final key in priceMap.keys) {
      final normKey = _normalizeAptName(key);
      if (normKey == norm ||
          normKey.contains(norm) ||
          norm.contains(normKey) ||
          _sharesCoreSubstring(norm, normKey)) {
        return key;
      }
    }
    return null;
  }

  // ── 실거래가 캐시 (Future를 저장해 동시 요청도 API 1회만 호출) ──────────────
  Future<Map<String, _MarkerPrice>> _getFastPriceMap(String lawdCd) =>
      _fastPriceMapCache.putIfAbsent(
        lawdCd,
        () => _fetchDistrictMonths(lawdCd, startOffset: 0, count: 3, numOfRows: 1000),
      );

  Future<Map<String, _MarkerPrice>> _getSupplementalPriceMap(String lawdCd) =>
      _supplementalPriceMapCache.putIfAbsent(
        lawdCd,
        () => _fetchDistrictMonths(lawdCd, startOffset: 3, count: 9, numOfRows: 200),
      );

  void _onMapTapped(NPoint point, NLatLng latLng) {
    // 맵 빈 곳 터치 시 드롭다운/키보드 닫기만 처리.
    // 바텀시트는 아파트 마커 탭 리스너(_fetchAndRenderBjdCode)에서 열립니다.
    if (_showDropdown) {
      FocusScope.of(context).unfocus();
      setState(() => _showDropdown = false);
    }
  }

  // ── 카카오 로컬 API 키워드 검색 (Debounce 적용) ──────────────────────────────

  void _onSearchChanged(String query) {
    if (_debounce?.isActive ?? false) _debounce!.cancel();

    if (query.trim().isEmpty) {
      setState(() {
        _searchResults = [];
        _showDropdown = false;
        _isSearching = false;
      });
      return;
    }

    // 0.3초 동안 추가 입력이 없으면 Kakao API 호출
    _debounce = Timer(const Duration(milliseconds: 300), () {
      _searchKakaoPlaces(query.trim());
    });
  }

  // ── 카카오 로컬 API — 키워드 장소 검색 ────────────────────────────────────────
  // GET https://dapi.kakao.com/v2/local/search/keyword.json?query=...&size=10
  // 응답 body['documents'] 각 항목: place_name, road_address_name,
  //   address_name, x(경도 String), y(위도 String), category_name
  Future<void> _searchKakaoPlaces(String query) async {
    if (!mounted) return;
    setState(() => _isSearching = true);

    try {
      final kakaoKey = dotenv.env['KAKAO_REST_API_KEY'];
      if (kakaoKey == null || kakaoKey.isEmpty) {
        if (mounted) {
          setState(() {
            _searchResults = [];
            _showDropdown = false;
          });
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('카카오 API 키가 설정되지 않았습니다.')),
          );
        }
        return;
      }

      final uri = Uri.parse(
        '$_kKakaoSearchUrl?query=${Uri.encodeComponent(query)}&size=10',
      );
      final res = await http.get(
        uri,
        headers: {'Authorization': 'KakaoAK $kakaoKey'},
      );

      if (!mounted) return;

      if (res.statusCode == 200) {
        final body = jsonDecode(res.body) as Map<String, dynamic>;
        setState(() {
          _searchResults = body['documents'] as List<dynamic>;
          _showDropdown = true;
        });
      } else {
        // 401: 잘못된 키 / 429: 쿼터 초과 등
        debugPrint('[Kakao API Error ${res.statusCode}] ${res.body}');
        setState(() {
          _searchResults = [];
          _showDropdown = false;
        });
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('검색 중 오류가 발생했습니다. 잠시 후 다시 시도해주세요.'),
            ),
          );
        }
      }
    } catch (e) {
      debugPrint('[Kakao API Exception] $e');
      if (mounted) {
        setState(() {
          _searchResults = [];
          _showDropdown = false;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('검색 중 오류가 발생했습니다. 잠시 후 다시 시도해주세요.'),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _isSearching = false);
    }
  }

  // 장소 클릭 시 동작
  Future<void> _onPlaceSelected(Map<String, dynamic> place) async {
    FocusScope.of(context).unfocus(); // 키보드 내리기
    setState(() {
      _showDropdown = false; // 드롭다운 닫기
      _searchController.text = place['place_name']; // 검색창에 장소명 세팅
    });

    final lat = double.parse(place['y']);
    final lng = double.parse(place['x']);
    final pos = NLatLng(lat, lng);
    final placeName = place['place_name'];

    // 카메라 이동
    await _mapController?.updateCamera(
      NCameraUpdate.scrollAndZoomTo(target: pos, zoom: 16),
    );

    // 기존 마커 삭제 후 새 마커 추가
    if (_searchMarker != null) {
      await _mapController?.deleteOverlay(_searchMarker!.info);
    }
    final marker = NMarker(id: 'search_result', position: pos);
    marker.setOnTapListener((_) => _showPropertyInfoSheet(pos, placeName));
    await _mapController?.addOverlay(marker);
    _searchMarker = marker;

    // 바텀 시트 띄우기
    if (mounted) _showPropertyInfoSheet(pos, placeName);
  }

  // ── Property Info Sheet ──────────────────────────────────────────────────

  /// [startOffset]달 전부터 [count]개월치 실거래 데이터를 가져와 단지명→가격/평수 맵 반환.
  /// - startOffset=0, count=3 → 이번달~2개월 전 (빠른 Path)
  /// - startOffset=3, count=9 → 3~11개월 전 (보완 Path)
  Future<Map<String, _MarkerPrice>> _fetchDistrictMonths(
    String lawdCd, {
    required int startOffset,
    required int count,
    required int numOfRows,
  }) async {
    try {
      final svc = const PublicDataService();
      final now = DateTime.now();

      final ymds = List.generate(count, (i) {
        final d = DateTime(now.year, now.month - startOffset - i);
        return '${d.year}${d.month.toString().padLeft(2, '0')}';
      });

      final results = await Future.wait(
        ymds.map((ymd) => svc.fetchAptTrades(
          lawdCd: lawdCd,
          dealYmd: ymd,
          numOfRows: numOfRows,
        )),
      );

      // 단지별 최근 실거래 1건 — 날짜(년·월·일) 내림차순 정렬 후 첫 번째 레코드
      final latestByComplex = <String, AptTradeRecord>{};
      for (final data in results) {
        for (final r in data.records) {
          if (r.price <= 0) continue;
          final name = r.complexName.trim();
          final existing = latestByComplex[name];
          if (existing == null ||
              r.dealYear > existing.dealYear ||
              (r.dealYear == existing.dealYear && r.dealMonth > existing.dealMonth) ||
              (r.dealYear == existing.dealYear &&
                  r.dealMonth == existing.dealMonth &&
                  r.dealDay > existing.dealDay)) {
            latestByComplex[name] = r;
          }
        }
      }

      final map = <String, _MarkerPrice>{};
      for (final entry in latestByComplex.entries) {
        final r = entry.value;
        map[entry.key] = _MarkerPrice(
          priceLabel: _fmtPrice(r.price),
          pyeongLabel: '${(r.area / 3.30579).round()}평',
        );
      }
      debugPrint(
        '[MapScreen] priceMap($lawdCd, offset=$startOffset, n=$count) → ${map.length}개 단지',
      );
      return map;
    } catch (e) {
      debugPrint('[MapScreen] priceMap 로드 실패: $e');
      return {};
    }
  }

  /// 만원 단위 → "N.M억" 표시 문자열.
  String _fmtPrice(int priceManWon) {
    final eok = priceManWon ~/ 10000;
    final man = priceManWon % 10000;
    if (eok > 0) {
      final decimal = man ~/ 1000;
      return decimal > 0 ? '$eok.$decimal억' : '$eok억';
    }
    return '${(priceManWon ~/ 100) * 100}만';
  }

  /// 실거래가 API 조회 연월 (YYYYMM). 이번 달 데이터가 없을 경우 호출부에서 폴백.
  String _currentDealYmd() {
    final now = DateTime.now();
    return '${now.year}${now.month.toString().padLeft(2, '0')}';
  }

  void _showPropertyInfoSheet(
    NLatLng pos,
    String label, {
    String lawdCd = '41135',
    ApartmentInfo? apt,
    String? apiName,
  }) {
    // 최근 본 매물 자동 저장 (로그인 상태일 때만, silently)
    RecentViewService().addView(
      id: apt?.kaptCode.isNotEmpty == true ? apt!.kaptCode : label,
      name: apt?.kaptName ?? label,
      address: apt?.kaptAddr ?? '',
      lat: pos.latitude,
      lng: pos.longitude,
    );

    showModalBottomSheet(
      context: context,
      useRootNavigator: true,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) {
        final sheetCtrl = DraggableScrollableController();
        return DraggableScrollableSheet(
          controller: sheetCtrl,
          initialChildSize: 0.72,
          minChildSize: 0.72,
          maxChildSize: 1.0,
          expand: false,
          snap: true,
          snapSizes: const [0.72, 1.0],
          builder: (_, scrollCtrl) => _PropertyInfoSheet(
            position: pos,
            label: label,
            lawdCd: lawdCd,
            dealYmd: _currentDealYmd(),
            scrollController: scrollCtrl,
            sheetController: sheetCtrl,
            apt: apt,
            apiName: apiName,
          ),
        );
      },
    );
  }

  // ── GPS 기능 ────────────────────────────────────────────────────────────
  Future<void> _requestLocationAndTrack() async {
    if (_isLocationLoading) return;
    setState(() => _isLocationLoading = true);

    try {
      final serviceEnabled = await Geolocator.isLocationServiceEnabled();
      if (!serviceEnabled) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('위치 서비스를 활성화해 주세요.')),
          );
        }
        return;
      }

      var permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
        if (permission == LocationPermission.denied) return;
      }
      if (permission == LocationPermission.deniedForever) {
        await openAppSettings();
        return;
      }

      // 현재 위치 가져오기
      final pos = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
        ),
      ).timeout(const Duration(seconds: 10));

      if (!mounted) return;

      // 카메라 이동
      await _mapController?.updateCamera(
        NCameraUpdate.scrollAndZoomTo(
          target: NLatLng(pos.latitude, pos.longitude),
          zoom: 15,
        ),
      );

      // 빨간 내 위치 점 표시
      _mapController?.setLocationTrackingMode(NLocationTrackingMode.noFollow);
      await _customizeLocationOverlay();
    } catch (e) {
      debugPrint('[MapScreen] 내 위치 이동 오류: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('현재 위치를 가져올 수 없습니다.')),
        );
      }
    } finally {
      if (mounted) setState(() => _isLocationLoading = false);
    }
  }

  /// 위치 오버레이를 빨간 점으로 커스터마이즈
  Future<void> _customizeLocationOverlay() async {
    if (_mapController == null || !mounted) return;
    final lo = _mapController!.getLocationOverlay();
    lo.setCircleColor(const Color(0x26FF3B30)); // 반투명 빨간 정확도 원
    lo.setCircleOutlineColor(const Color(0x55FF3B30));
    lo.setCircleOutlineWidth(1.0);
    try {
      final icon = await NOverlayImage.fromWidget(
        context: context,
        size: const Size(22, 22),
        widget: Container(
          width: 22,
          height: 22,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: const Color(0xFFFF3B30),
            border: Border.all(color: Colors.white, width: 2.5),
            boxShadow: const [
              BoxShadow(
                color: Color(0x40000000),
                blurRadius: 4,
                offset: Offset(0, 2),
              ),
            ],
          ),
        ),
      );
      if (mounted) {
        lo.setIcon(icon);
        lo.setIconSize(const Size(22, 22));
      }
    } catch (e) {
      debugPrint('[MapScreen] 위치 아이콘 커스텀 실패: $e');
    }
  }

  // ── Widget builders ──────────────────────────────────────────────────────

  Widget _buildSearchBar() {
    // 드롭다운이 열려 있을 때: 하단 모서리를 평탄화하여 연결된 카드처럼 표현
    final connected = _showDropdown && _searchResults.isNotEmpty;
    final barRadius = connected
        ? const BorderRadius.only(
            topLeft: Radius.circular(26),
            topRight: Radius.circular(26),
            bottomLeft: Radius.circular(4),
            bottomRight: Radius.circular(4),
          )
        : BorderRadius.circular(26);

    return Container(
      height: 52,
      decoration: BoxDecoration(
        color: kSurface,
        borderRadius: barRadius,
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.13),
            blurRadius: 18,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Row(
        children: [
          const SizedBox(width: 16),
          _isSearching
              ? const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: kPrimary,
                  ),
                )
              : Icon(
                  Icons.search_rounded,
                  color: Colors.grey.shade400,
                  size: 22,
                ),
          const SizedBox(width: 10),
          Expanded(
            child: TextField(
              controller: _searchController,
              onChanged: _onSearchChanged, // 타이핑 할 때마다 호출
              textInputAction: TextInputAction.search,
              style: const TextStyle(fontSize: 15, color: kTextDark),
              decoration: InputDecoration(
                hintText: '아파트명 또는 지역 검색 (예: 청솔주공)',
                hintStyle: TextStyle(color: Colors.grey.shade400),
                filled: false,
                border: InputBorder.none,
                enabledBorder: InputBorder.none,
                focusedBorder: InputBorder.none,
                isDense: true,
                contentPadding: EdgeInsets.zero,
              ),
            ),
          ),
          ValueListenableBuilder<TextEditingValue>(
            valueListenable: _searchController,
            builder: (_, val, _) {
              if (val.text.isEmpty) return const SizedBox(width: 16);
              return GestureDetector(
                onTap: () {
                  _searchController.clear();
                  _onSearchChanged('');
                },
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  child: Icon(
                    Icons.cancel_rounded,
                    color: Colors.grey.shade400,
                    size: 18,
                  ),
                ),
              );
            },
          ),
        ],
      ),
    );
  }

  // ── 검색 결과 드롭다운 ──────────────────────────────────────────────────────
  // 검색창과 2px 간격으로 연결된 카드 형태. 상단 모서리는 평탄, 하단은 둥글게.
  Widget _buildDropdownList() {
    const dropRadius = BorderRadius.only(
      topLeft: Radius.circular(4),
      topRight: Radius.circular(4),
      bottomLeft: Radius.circular(20),
      bottomRight: Radius.circular(20),
    );

    return Container(
      margin: const EdgeInsets.only(top: 2),
      constraints: const BoxConstraints(maxHeight: 296),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: dropRadius,
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.11),
            blurRadius: 16,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: dropRadius,
        child: ListView.separated(
          padding: const EdgeInsets.symmetric(vertical: 6),
          shrinkWrap: true,
          itemCount: _searchResults.length,
          separatorBuilder: (_, __) => Divider(
            height: 1,
            thickness: 1,
            color: Colors.grey.shade100,
            indent: 16,
            endIndent: 16,
          ),
          itemBuilder: (context, index) {
            final place = _searchResults[index];
            final address = (place['road_address_name'] as String).isNotEmpty
                ? place['road_address_name'] as String
                : place['address_name'] as String;

            return InkWell(
              onTap: () => _onPlaceSelected(place),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 10,
                ),
                child: Row(
                  children: [
                    // 아파트 아이콘 배지
                    Container(
                      width: 38,
                      height: 38,
                      decoration: BoxDecoration(
                        color: kPrimary.withValues(alpha: 0.08),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: const Icon(
                        Icons.apartment_rounded,
                        color: kPrimary,
                        size: 20,
                      ),
                    ),
                    const SizedBox(width: 12),
                    // 장소명 + 주소
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            place['place_name'] as String,
                            style: const TextStyle(
                              fontWeight: FontWeight.w700,
                              fontSize: 14,
                              color: kTextDark,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          const SizedBox(height: 2),
                          Text(
                            address,
                            style: TextStyle(
                              fontSize: 12,
                              color: Colors.grey.shade500,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 8),
                    // 카테고리 뱃지
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 7,
                        vertical: 3,
                      ),
                      decoration: BoxDecoration(
                        color: kSecondary.withValues(alpha: 0.10),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: const Text(
                        '아파트',
                        style: TextStyle(
                          fontSize: 10,
                          fontWeight: FontWeight.w700,
                          color: kSecondary,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  Widget _buildMyLocationButton() {
    return Container(
      width: 44,
      height: 44,
      decoration: BoxDecoration(
        color: kSurface,
        shape: BoxShape.circle,
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.15),
            blurRadius: 10,
            offset: const Offset(0, 3),
          ),
        ],
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(22),
          onTap: _requestLocationAndTrack,
          child: Center(
            child: _isLocationLoading
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: kPrimary,
                    ),
                  )
                : const Icon(
                    Icons.my_location_rounded,
                    color: kPrimary,
                    size: 22,
                  ),
          ),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// 부동산 정보 바텀시트 — 탭 3개: 단지정보 / 시세 / 임장노트
// ─────────────────────────────────────────────────────────────────────────────

class _PropertyInfoSheet extends StatefulWidget {
  const _PropertyInfoSheet({
    required this.position,
    required this.label,
    required this.lawdCd,
    required this.dealYmd,
    required this.scrollController,
    required this.sheetController,
    this.apt,
    this.apiName,
  });

  final NLatLng position;
  final String label, lawdCd, dealYmd;
  final ScrollController scrollController;
  final DraggableScrollableController sheetController;
  final ApartmentInfo? apt;
  final String? apiName; // priceMap 매칭으로 확인된 API 단지명

  @override
  State<_PropertyInfoSheet> createState() => _PropertyInfoSheetState();
}

class _PropertyInfoSheetState extends State<_PropertyInfoSheet>
    with SingleTickerProviderStateMixin {
  late final TabController _tabCtrl;
  late final Future<List<AptTradeRecord>> _tradeFuture;
  String? _apiName; // trade records에서 도출한 API 단지명 (aptNm)

  // 임장노트 입력용
  final _reviewCtrl = TextEditingController();
  final _picker = ImagePicker();
  final _favService = FavoriteService();
  final List<XFile> _pendingMedia = [];
  bool _isSaving = false;

  String get _favoriteId {
    final code = widget.apt?.kaptCode ?? '';
    return code.isNotEmpty ? code : widget.label;
  }

  @override
  void initState() {
    super.initState();
    _tabCtrl = TabController(length: 3, vsync: this);
    // priceMap에서 이미 매칭된 API 이름이 있으면 즉시 사용
    _apiName = widget.apiName;
    _tradeFuture = _loadTradeDataCached().then((records) {
      // apiName이 없을 때만 records에서 도출 시도
      if (_apiName == null) {
        final kaptName = widget.apt?.kaptName.trim() ?? widget.label;
        final resolved = _resolveApiName(records, kaptName);
        if (resolved != null && mounted) {
          setState(() => _apiName = resolved);
        }
      }
      return records;
    });
  }

  @override
  void dispose() {
    widget.sheetController.dispose();
    _tabCtrl.dispose();
    _reviewCtrl.dispose();
    super.dispose();
  }

  String _todayStr() {
    final now = DateTime.now();
    return '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
  }

  /// 시세 데이터 로드: Firestore 캐시(오늘 날짜) → 없으면 API 호출 후 저장.
  Future<List<AptTradeRecord>> _loadTradeDataCached() async {
    final db = FirebaseFirestore.instance;
    final cacheRef = db.collection('apt_price_cache').doc(widget.lawdCd);
    final today = _todayStr();

    // ── 캐시 확인 ────────────────────────────────────────────────────────────
    try {
      final snap = await cacheRef.get();
      if (snap.exists) {
        final data = snap.data()!;
        if (data['cachedDate'] == today) {
          final rawList =
              List<Map<String, dynamic>>.from(data['records'] ?? []);
          debugPrint('[Sheet] 캐시 히트 — ${rawList.length}건');
          return rawList.map((m) => AptTradeRecord.fromMap(m)).toList();
        }
      }
    } catch (e) {
      debugPrint('[Sheet] 캐시 읽기 실패: $e');
    }

    // ── API 호출 ─────────────────────────────────────────────────────────────
    final svc = const PublicDataService();
    AptTradeData data = await svc.fetchAptTrades(
      lawdCd: widget.lawdCd,
      dealYmd: widget.dealYmd,
    );

    if (data.records.isEmpty) {
      final now = DateTime.now();
      final prev = DateTime(now.year, now.month - 1);
      data = await svc.fetchAptTrades(
        lawdCd: widget.lawdCd,
        dealYmd: '${prev.year}${prev.month.toString().padLeft(2, '0')}',
      );
    }

    // ── 캐시 저장 (실패해도 무시) ──────────────────────────────────────────────
    try {
      await cacheRef.set({
        'cachedDate': today,
        'records': data.records.map((r) => r.toMap()).toList(),
        'fetchedAt': FieldValue.serverTimestamp(),
      });
    } catch (e) {
      debugPrint('[Sheet] 캐시 저장 실패: $e');
    }

    return data.records;
  }

  Future<void> _toggleFavorite(bool isFav) async {
    if (FirebaseAuth.instance.currentUser == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('로그인 후 관심 매물을 저장할 수 있습니다.'),
          margin: EdgeInsets.all(16),
        ),
      );
      return;
    }
    try {
      if (isFav) {
        await _favService.removeFavorite(_favoriteId);
      } else {
        final item = widget.apt != null
            ? FavoriteItem.fromApartmentInfo(widget.apt!)
            : FavoriteItem.fromLabel(
                label: widget.label,
                lat: widget.position.latitude,
                lng: widget.position.longitude,
              );
        await _favService.addFavorite(item);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('오류: $e'),
            margin: const EdgeInsets.all(16),
          ),
        );
      }
    }
  }

  bool get _canSubmit =>
      (_reviewCtrl.text.trim().isNotEmpty || _pendingMedia.isNotEmpty) &&
      !_isSaving;

  Future<void> _pickImages() async {
    if (_isSaving) return;
    final picked = await _picker.pickMultiImage(imageQuality: 85);
    if (picked.isNotEmpty && mounted) setState(() => _pendingMedia.addAll(picked));
  }

  // ── 주소 파싱 헬퍼 (imjang_records 저장용) ────────────────────────────────

  static String _parseSido(String address) {
    if (address.isEmpty) return '';
    final p = address.split(' ').first;
    if (p.contains('서울')) return '서울';
    if (p.contains('경기')) return '경기';
    if (p.contains('인천')) return '인천';
    if (p.contains('부산')) return '부산';
    if (p.contains('대구')) return '대구';
    if (p.contains('광주')) return '광주';
    if (p.contains('대전')) return '대전';
    if (p.contains('울산')) return '울산';
    if (p.contains('세종')) return '세종';
    if (p.contains('강원')) return '강원';
    if (p.contains('충북') || (p.contains('충청') && p.contains('북'))) return '충북';
    if (p.contains('충남') || (p.contains('충청') && p.contains('남'))) return '충남';
    if (p.contains('전북') || (p.contains('전라') && p.contains('북'))) return '전북';
    if (p.contains('전남') || (p.contains('전라') && p.contains('남'))) return '전남';
    if (p.contains('경북') || (p.contains('경상') && p.contains('북'))) return '경북';
    if (p.contains('경남') || (p.contains('경상') && p.contains('남'))) return '경남';
    if (p.contains('제주')) return '제주';
    return p;
  }

  static String _parseSigungu(String address) {
    final parts = address.split(' ');
    if (parts.length < 2) return '';
    final p1 = parts[1];
    if (parts.length >= 3) {
      final p2 = parts[2];
      if ((p1.endsWith('시') || p1.endsWith('군')) && p2.endsWith('구')) {
        return '$p1 $p2';
      }
    }
    return p1;
  }

  static String _parseEupmyeondong(String address) {
    final parts = address.split(' ');
    for (int i = parts.length - 1; i >= 0; i--) {
      final p = parts[i];
      if (p.endsWith('동') || p.endsWith('읍') || p.endsWith('면')) return p;
    }
    return '';
  }

  static String _deriveRegion(String address) {
    if (address.contains('서울')) return '서울';
    if (address.contains('경기') || address.contains('인천')) return '경기/인천';
    if (address.contains('부산') || address.contains('경남')) return '부산/경남';
    return '지방';
  }

  Future<void> _submit() async {
    if (!_canSubmit) return;
    if (FirebaseAuth.instance.currentUser == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('로그인 후 임장 기록을 남길 수 있습니다.')),
      );
      return;
    }
    setState(() => _isSaving = true);
    try {
      final imageFiles = _pendingMedia.map((f) => File(f.path)).toList();
      final reviewText = _reviewCtrl.text.trim();
      final address = widget.apt?.kaptAddr.isNotEmpty == true
          ? widget.apt!.kaptAddr
          : widget.label;
      final bId = HouseLogService.buildingId(widget.label);

      await ImjangService().saveImjangRecord(
        title: widget.label,
        address: address,
        region: _deriveRegion(address),
        latitude: widget.position.latitude,
        longitude: widget.position.longitude,
        review: reviewText,
        mediaFiles: imageFiles,
        sido: _parseSido(address),
        sigungu: _parseSigungu(address),
        eupmyeondong: _parseEupmyeondong(address),
        buildingId: bId,
      );
      if (mounted) {
        setState(() {
          _reviewCtrl.clear();
          _pendingMedia.clear();
          _isSaving = false;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('임장 기록이 등록되었습니다.')),
        );
      }
    } catch (e) {
      if (mounted) {
        setState(() => _isSaving = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('저장 실패: $e'),
            backgroundColor: Colors.red.shade700,
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: widget.sheetController,
      builder: (ctx, _) => _buildSheet(ctx),
    );
  }

  Widget _buildSheet(BuildContext context) {
    final isFullScreen = widget.sheetController.isAttached &&
        widget.sheetController.size >= 0.99;
    final topPadding = isFullScreen ? MediaQuery.of(context).padding.top : 0.0;
    return Container(
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: _kPageBg,
        borderRadius: isFullScreen
            ? BorderRadius.zero
            : const BorderRadius.vertical(top: Radius.circular(24)),
      ),
      padding: EdgeInsets.only(top: topPadding),
      child: Column(
        children: [
          // 드래그 핸들: scrollController를 연결한 ListView
          // → DraggableScrollableSheet가 이 scroll 이벤트로 시트 크기 제어
          SizedBox(
            height: 32,
            child: ListView(
              controller: widget.scrollController,
              physics: const AlwaysScrollableScrollPhysics(),
              children: [
                Center(
                  child: Container(
                    margin: const EdgeInsets.symmetric(vertical: 14),
                    width: 36,
                    height: 4,
                    decoration: BoxDecoration(
                      color: Colors.grey.shade300,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
              ],
            ),
          ),
          // 단지 헤더
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: _buildComplexHeader(),
          ),
          // 탭바
          TabBar(
            controller: _tabCtrl,
            labelColor: kPrimary,
            unselectedLabelColor: kTextMuted,
            indicatorColor: kPrimary,
            indicatorWeight: 2.5,
            labelStyle: const TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w700,
            ),
            unselectedLabelStyle: const TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w500,
            ),
            tabs: const [
              Tab(text: '단지정보'),
              Tab(text: '시세'),
              Tab(text: '임장노트'),
            ],
          ),
          const Divider(height: 1, thickness: 1),
          // 탭 콘텐츠
          Expanded(
            child: TabBarView(
              controller: _tabCtrl,
              children: [
                _ComplexInfoTab(
                  apt: widget.apt,
                  label: widget.label,
                  tradeFuture: _tradeFuture,
                  apiName: _apiName,
                ),
                _PriceTab(
                  lawdCd: widget.lawdCd,
                  aptName: _apiName ?? widget.apt?.kaptName.trim() ?? widget.label,
                ),
                _ImjangNotesTab(
                  label: widget.label,
                  reviewCtrl: _reviewCtrl,
                  pendingMedia: _pendingMedia,
                  isSaving: _isSaving,
                  canSubmit: _canSubmit,
                  onPickImages: _pickImages,
                  onSubmit: _submit,
                  onRemoveMedia: (i) =>
                      setState(() => _pendingMedia.removeAt(i)),
                  onTextChanged: () => setState(() {}),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildComplexHeader() {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 3,
                    ),
                    decoration: BoxDecoration(
                      color: kPrimary.withValues(alpha: 0.08),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: const Text(
                      '아파트',
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                        color: kPrimary,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      widget.apt?.kaptAddr ?? '',
                      style: const TextStyle(fontSize: 11, color: kTextMuted),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              Text(
                widget.label,
                style: const TextStyle(
                  fontSize: 22,
                  fontWeight: FontWeight.w800,
                  color: kTextDark,
                  letterSpacing: -0.7,
                  height: 1.1,
                ),
              ),
            ],
          ),
        ),
        StreamBuilder<bool>(
          stream: _favService.isFavoriteStream(_favoriteId),
          builder: (ctx, snap) {
            final isFav = snap.data ?? false;
            return GestureDetector(
              onTap: () => _toggleFavorite(isFav),
              child: Padding(
                padding: const EdgeInsets.only(left: 8, top: 4),
                child: Icon(
                  isFav
                      ? Icons.favorite_rounded
                      : Icons.favorite_outline_rounded,
                  color: isFav
                      ? const Color(0xFFE53935)
                      : Colors.grey.shade400,
                  size: 28,
                ),
              ),
            );
          },
        ),
      ],
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// 탭 1: 단지정보
// ─────────────────────────────────────────────────────────────────────────────

class _ComplexInfoTab extends StatelessWidget {
  const _ComplexInfoTab({
    required this.apt,
    required this.label,
    required this.tradeFuture,
    this.apiName,
  });

  final ApartmentInfo? apt;
  final String label;
  final Future<List<AptTradeRecord>> tradeFuture;
  final String? apiName;

  static String _parkingLabel(int total, int households) {
    if (households > 0) {
      final perUnit = total / households;
      return '$total대 (세대당 ${perUnit.toStringAsFixed(2)}대)';
    }
    return '$total대';
  }

  @override
  Widget build(BuildContext context) {
    final a = apt; // null-safe 로컬 참조
    return FutureBuilder<List<AptTradeRecord>>(
      future: tradeFuture,
      builder: (ctx, snap) {
        // 건축년도 추출 (실거래 데이터 기반)
        int buildYear = 0;
        if (snap.hasData) {
          final years = snap.data!
              .map((r) => r.buildYear)
              .where((y) => y > 0)
              .toList();
          if (years.isNotEmpty) {
            final freq = <int, int>{};
            for (final y in years) {
              freq[y] = (freq[y] ?? 0) + 1;
            }
            buildYear = freq.entries
                .reduce((best, e) => e.value >= best.value ? e : best)
                .key;
          }
        }

        // 순서: 단지명, 건축년도, 세대수, 주차대수, 난방, 사용승인일, 저/최고층, 건설사, 도로명주소, 지번주소
        final rows = <Widget>[
          _InfoRow(label: '단지명', value: apiName ?? a?.kaptName ?? label),
          if (snap.connectionState == ConnectionState.waiting)
            const _LoadingRow()
          else if (buildYear > 0)
            _InfoRow(label: '건축년도', value: '$buildYear년'),
          if (a != null && a.totalHouseholds > 0)
            _InfoRow(
              label: '세대수',
              value: '${a.totalHouseholds}세대'
                  '${a.dongCount > 0 ? ' (${a.dongCount}개동)' : ''}',
            ),
          if (a != null && a.totalParkingCount > 0)
            _InfoRow(
              label: '주차대수',
              value: _parkingLabel(a.totalParkingCount, a.totalHouseholds),
            ),
          if (a != null && a.heatingType.isNotEmpty)
            _InfoRow(label: '난방', value: a.heatingType),
          if (a != null && a.approvalDate.isNotEmpty)
            _InfoRow(label: '사용승인일', value: a.approvalDate),
          if (a != null && (a.minFloor > 0 || a.maxFloor > 0))
            _InfoRow(
              label: '저/최고층',
              value: '${a.minFloor < 1 ? 1 : a.minFloor}층 / ${a.maxFloor < 1 ? 1 : a.maxFloor}층',
            ),
          if (a != null && a.builder.isNotEmpty)
            _InfoRow(label: '건설사', value: a.builder),
          if (a != null && a.roadAddr.isNotEmpty)
            _InfoRow(label: '도로명주소', value: a.roadAddr),
          _InfoRow(
            label: '지번주소',
            value: a?.kaptAddr.isNotEmpty == true ? a!.kaptAddr : '-',
          ),
        ];

        return SingleChildScrollView(
          padding: EdgeInsets.fromLTRB(
            16, 16, 16, MediaQuery.of(context).padding.bottom + 16,
          ),
          child: _InfoCard(children: rows),
        );
      },
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// 탭 2: 시세
// ─────────────────────────────────────────────────────────────────────────────

class _PriceTab extends StatefulWidget {
  const _PriceTab({required this.lawdCd, required this.aptName});
  final String lawdCd;
  final String aptName;

  @override
  State<_PriceTab> createState() => _PriceTabState();
}

class _PriceTabState extends State<_PriceTab> {
  int _years = 1;
  int? _selectedPyeong;

  // yyyymm → 전체 지역 실거래 레코드 (원본)
  final Map<String, List<AptTradeRecord>> _rawCache = {};
  // yyyymm → 필터링된 단지 레코드
  final Map<String, List<AptTradeRecord>> _cache = {};

  bool _isLoading = false;

  @override
  void initState() {
    super.initState();
    _loadYears(1);
  }

  @override
  void didUpdateWidget(_PriceTab old) {
    super.didUpdateWidget(old);
    // aptName이 나중에 resolve되면 기존 원본 캐시를 재필터링
    if (old.aptName != widget.aptName && widget.aptName.isNotEmpty) {
      setState(() {
        for (final key in _rawCache.keys) {
          _cache[key] = _filter(_rawCache[key]!);
        }
      });
    }
  }

  Future<void> _loadYears(int targetYears) async {
    if (_isLoading) return;
    setState(() {
      _isLoading = true;
    });

    final now = DateTime.now();
    final allMonths = <String>[];
    for (int i = 0; i < targetYears * 12; i++) {
      final d = DateTime(now.year, now.month - i);
      allMonths.add('${d.year}${d.month.toString().padLeft(2, '0')}');
    }
    final toLoad = allMonths.where((m) => !_cache.containsKey(m)).toList();

    for (int i = 0; i < toLoad.length; i += 6) {
      final batch = toLoad.sublist(i, min(i + 6, toLoad.length));
      await Future.wait(batch.map(_fetchMonth));
      if (mounted) setState(() {}); // 배치마다 점진적 업데이트
    }

    if (mounted) {
      setState(() {
        _isLoading = false;
        _years = targetYears;
      });
    }
  }

  Future<void> _fetchMonth(String yyyymm) async {
    final db = FirebaseFirestore.instance;
    final cacheKey = '${widget.lawdCd}_$yyyymm';
    final cacheRef = db.collection('apt_price_cache_v2').doc(cacheKey);
    List<AptTradeRecord>? allRecords;

    // 최근 2개월(이번달·지난달)은 당일 캐시가 아니면 재조회,
    // 그 이전 달은 Firestore 캐시 있으면 API 호출 없이 그대로 사용.
    final now = DateTime.now();
    final prevMonth = DateTime(now.year, now.month - 1);
    final recentKeys = {
      '${now.year}${now.month.toString().padLeft(2, '0')}',
      '${prevMonth.year}${prevMonth.month.toString().padLeft(2, '0')}',
    };
    final isRecent = recentKeys.contains(yyyymm);

    // 1) Firestore 캐시 확인
    try {
      final snap = await cacheRef.get();
      if (snap.exists) {
        final data = snap.data()!;
        bool useCache;

        if (isRecent) {
          // 최근 달: 오늘 캐시된 것만 유효 (당일 중복 API 호출 방지)
          final fetchedAt = data['fetchedAt'] as Timestamp?;
          if (fetchedAt != null) {
            final fd = fetchedAt.toDate().toLocal();
            useCache = fd.year == now.year &&
                fd.month == now.month &&
                fd.day == now.day;
          } else {
            useCache = false; // 날짜 없는 구버전 캐시 → 재조회
          }
        } else {
          // 과거 달: 캐시가 있으면 무조건 사용
          useCache = true;
        }

        if (useCache) {
          final rawList =
              List<Map<String, dynamic>>.from(data['records'] ?? []);
          allRecords = rawList.map(AptTradeRecord.fromMap).toList();
        }
      }
    } catch (_) {}

    // 2) 캐시 없거나 재조회 필요 시 API 호출
    if (allRecords == null) {
      try {
        final data = await const PublicDataService().fetchAptTrades(
          lawdCd: widget.lawdCd,
          dealYmd: yyyymm,
          numOfRows: 1000,
        );
        allRecords = data.records;
        // 중복 제거 후 Firestore 저장 (set으로 덮어쓰기)
        try {
          final seen = <String>{};
          final deduped = allRecords.where((r) {
            final key =
                '${r.complexName}_${r.dealYear}_${r.dealMonth}_${r.dealDay}_${r.floor}_${r.area}';
            return seen.add(key);
          }).toList();
          await cacheRef.set({
            'records': deduped.map((r) => r.toMap()).toList(),
            'fetchedAt': FieldValue.serverTimestamp(),
          });
        } catch (_) {}
      } catch (_) {
        allRecords = [];
      }
    }

    _rawCache[yyyymm] = allRecords;
    _cache[yyyymm] = _filter(allRecords);
  }

  List<AptTradeRecord> _filter(List<AptTradeRecord> records) {
    final name = widget.aptName.trim();
    if (name.isEmpty) return records;
    final filtered = records.where((r) {
      final rn = r.complexName.trim();
      return rn == name || rn.contains(name) || name.contains(rn);
    }).toList();
    return filtered.isNotEmpty ? filtered : [];
  }

  List<AptTradeRecord> get _allFiltered {
    final all = _cache.values.expand((l) => l).toList();
    all.sort((a, b) {
      final da = DateTime(a.dealYear, a.dealMonth, max(a.dealDay, 1));
      final db2 = DateTime(b.dealYear, b.dealMonth, max(b.dealDay, 1));
      return db2.compareTo(da);
    });
    return all;
  }

  List<int> get _pyeongList {
    final freq = <int, int>{};
    for (final r in _allFiltered) {
      final p = (r.area / 3.30579).round();
      if (p > 0) freq[p] = (freq[p] ?? 0) + 1;
    }
    return freq.keys.toList()..sort();
  }

  int? get _mostCommonPyeong {
    final freq = <int, int>{};
    for (final r in _allFiltered) {
      final p = (r.area / 3.30579).round();
      if (p > 0) freq[p] = (freq[p] ?? 0) + 1;
    }
    if (freq.isEmpty) return null;
    return freq.entries.reduce((a, b) => a.value >= b.value ? a : b).key;
  }

  List<AptTradeRecord> get _pyeongFiltered {
    final p = _selectedPyeong;
    if (p == null) return _allFiltered;
    return _allFiltered
        .where((r) => (r.area / 3.30579).round() == p)
        .toList();
  }

  List<MapEntry<DateTime, int>> get _chartPoints {
    final monthMap = <String, List<int>>{};
    for (final r in _pyeongFiltered) {
      if (r.price <= 0) continue;
      final key =
          '${r.dealYear}${r.dealMonth.toString().padLeft(2, '0')}';
      monthMap.putIfAbsent(key, () => []).add(r.price);
    }
    final pts = monthMap.entries.map((e) {
      final avg = e.value.reduce((a, b) => a + b) ~/ e.value.length;
      return MapEntry(
        DateTime(
          int.parse(e.key.substring(0, 4)),
          int.parse(e.key.substring(4)),
        ),
        avg,
      );
    }).toList()
      ..sort((a, b) => a.key.compareTo(b.key));
    return pts;
  }

  /// 개별 거래 건 좌표 목록 (그래프 스캐터 점 용)
  List<MapEntry<DateTime, int>> get _rawChartDots {
    return _pyeongFiltered
        .where((r) => r.price > 0)
        .map((r) => MapEntry(
              DateTime(r.dealYear, r.dealMonth, r.dealDay > 0 ? r.dealDay : 1),
              r.price,
            ))
        .toList()
      ..sort((a, b) => a.key.compareTo(b.key));
  }

  @override
  Widget build(BuildContext context) {
    final pyeongs = _pyeongList;
    final filtered = _pyeongFiltered;
    final chartPts = _chartPoints;
    final rawDots = _rawChartDots;

    // 가장 많이 거래된 평형 자동 선택
    if (_selectedPyeong == null && pyeongs.isNotEmpty) {
      final auto = _mostCommonPyeong;
      if (auto != null) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted && _selectedPyeong == null) {
            setState(() => _selectedPyeong = auto);
          }
        });
      }
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // ── 필터 행: 왼쪽 = 기간(연도), 오른쪽 = 평형 ─────────────────────────
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 0),
          child: Row(
            children: [
              // 기간 드롭다운 (왼쪽)
              _FilterDropdown<int>(
                value: _years,
                hint: '기간',
                items: const [1, 3, 5, 10],
                label: (y) => '$y년',
                enabled: !_isLoading,
                onChanged: (v) => _loadYears(v),
              ),
              const SizedBox(width: 10),
              // 평형 드롭다운 (오른쪽)
              _FilterDropdown<int?>(
                value: _selectedPyeong,
                hint: '평형',
                items: [null, ...pyeongs],
                label: (p) => p == null ? '전체' : '$p평',
                enabled: pyeongs.isNotEmpty,
                onChanged: (v) => setState(() => _selectedPyeong = v),
              ),
            ],
          ),
        ),

        // ── 로딩 바 ─────────────────────────────────────────────────────────
        if (_isLoading)
          const Padding(
            padding: EdgeInsets.only(top: 6),
            child: LinearProgressIndicator(minHeight: 2),
          )
        else
          const SizedBox(height: 6),

        // ── 시세 그래프 ──────────────────────────────────────────────────────
        if (chartPts.length >= 2) ...[
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
            child: Text(
              '월평균 실거래가'
              '${_selectedPyeong != null ? ' ($_selectedPyeong평)' : ''}',
              style: const TextStyle(
                fontSize: 12,
                color: kTextMuted,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
          SizedBox(
            height: 180,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(4, 4, 12, 4),
              child: CustomPaint(
                painter: _PriceChartPainter(
                  monthlyAvgs: chartPts,
                  rawDots: rawDots,
                ),
                size: Size.infinite,
              ),
            ),
          ),
        ] else if (!_isLoading && pyeongs.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 16),
            child: Center(
              child: Text(
                '실거래 데이터가 없습니다.',
                style: TextStyle(color: kTextMuted, fontSize: 13),
              ),
            ),
          ),

        // ── 실거래 내역 섹션 헤더 ────────────────────────────────────────────
        const Padding(
          padding: EdgeInsets.fromLTRB(14, 14, 14, 6),
          child: Row(
            children: [
              Text(
                '실거래 내역',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  color: kTextMuted,
                  letterSpacing: 0.2,
                ),
              ),
            ],
          ),
        ),
        const Divider(height: 1, thickness: 0.5, indent: 14, endIndent: 14),

        // ── 거래 목록 ────────────────────────────────────────────────────────
        Expanded(
          child: filtered.isEmpty
              ? Center(
                  child: _isLoading
                      ? const CircularProgressIndicator(strokeWidth: 2)
                      : const Text(
                          '거래 내역이 없습니다.',
                          style: TextStyle(color: kTextMuted, fontSize: 13),
                        ),
                )
              : ListView.builder(
                  padding: const EdgeInsets.fromLTRB(12, 6, 12, 32),
                  itemCount: filtered.length,
                  itemBuilder: (_, i) => _TradeCard(record: filtered[i]),
                ),
        ),
      ],
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// 시세 그래프 페인터 — 네이버 부동산 스타일
//   · rawDots   : 개별 거래 건 (작은 반투명 점)
//   · monthlyAvgs: 월평균 (굵은 선 + 채우기 + 강조 점)
// ─────────────────────────────────────────────────────────────────────────────

class _PriceChartPainter extends CustomPainter {
  const _PriceChartPainter({
    required this.monthlyAvgs,
    required this.rawDots,
  });

  final List<MapEntry<DateTime, int>> monthlyAvgs; // 월별 평균 (선)
  final List<MapEntry<DateTime, int>> rawDots;     // 개별 거래 (점)

  @override
  void paint(Canvas canvas, Size size) {
    if (monthlyAvgs.length < 2) return;

    const leftPad = 58.0;
    const rightPad = 8.0;
    const topPad = 12.0;
    const bottomPad = 28.0;

    final chartW = size.width - leftPad - rightPad;
    final chartH = size.height - topPad - bottomPad;

    // ── 전체 가격 범위 (rawDots + monthlyAvgs 합산) ─────────────────────────
    final allPrices = [
      ...monthlyAvgs.map((e) => e.value.toDouble()),
      ...rawDots.map((e) => e.value.toDouble()),
    ];
    final minP = allPrices.reduce(min);
    final maxP = allPrices.reduce(max);
    final rawRange = maxP - minP;
    // Y 범위에 여백 추가 (상하 10%)
    final padP = rawRange * 0.10;
    final yMin = (minP - padP).clamp(0, double.infinity);
    final yMax = maxP + padP;
    final range = (yMax - yMin).clamp(1, double.infinity);

    // ── 날짜 범위 (시간 기반 X축) ───────────────────────────────────────────
    final allDates = [
      ...monthlyAvgs.map((e) => e.key),
      ...rawDots.map((e) => e.key),
    ];
    final minDate = allDates.reduce((a, b) => a.isBefore(b) ? a : b);
    final maxDate = allDates.reduce((a, b) => a.isAfter(b) ? a : b);
    final totalMs =
        (maxDate.millisecondsSinceEpoch - minDate.millisecondsSinceEpoch)
            .toDouble()
            .clamp(1, double.infinity);

    // ── 좌표 변환 헬퍼 ─────────────────────────────────────────────────────
    Offset toOffset(DateTime date, int price) {
      final x = leftPad +
          chartW *
              (date.millisecondsSinceEpoch - minDate.millisecondsSinceEpoch) /
              totalMs;
      final y = topPad + chartH * (1 - (price - yMin) / range);
      return Offset(x, y);
    }

    final textStyle = TextStyle(color: Colors.grey.shade500, fontSize: 9.5);

    // ── 수평 그리드 ────────────────────────────────────────────────────────
    final gridPaint = Paint()
      ..color = Colors.grey.shade100
      ..strokeWidth = 1;
    for (int i = 0; i <= 4; i++) {
      final y = topPad + chartH * i / 4;
      canvas.drawLine(
          Offset(leftPad, y), Offset(size.width - rightPad, y), gridPaint);
    }

    // ── Y 축 레이블 ────────────────────────────────────────────────────────
    for (int i = 0; i <= 4; i++) {
      final price = yMin + range * (4 - i) / 4;
      final y = topPad + chartH * i / 4;
      final label = _priceLabel(price.round());
      final tp = TextPainter(
        text: TextSpan(text: label, style: textStyle),
        textDirection: TextDirection.ltr,
      )..layout(maxWidth: leftPad - 6);
      tp.paint(canvas, Offset(leftPad - tp.width - 5, y - tp.height / 2));
    }

    // ── X 축 월 레이블 ─────────────────────────────────────────────────────
    final n = monthlyAvgs.length;
    final step = n > 36 ? 12 : (n > 18 ? 6 : (n > 8 ? 3 : 2));
    for (int i = 0; i < n; i += step) {
      final d = monthlyAvgs[i].key;
      final o = toOffset(d, yMin.round());
      final label =
          "${d.year.toString().substring(2)}.${d.month.toString().padLeft(2, '0')}";
      final tp = TextPainter(
        text: TextSpan(text: label, style: textStyle),
        textDirection: TextDirection.ltr,
      )..layout(maxWidth: 44);
      tp.paint(canvas, Offset(o.dx - tp.width / 2, size.height - bottomPad + 6));
    }

    // ── 개별 거래 점 (rawDots) ─────────────────────────────────────────────
    // 네이버 부동산처럼 작고 반투명한 회색 점으로 실거래를 표시
    final rawPaint = Paint()
      ..color = const Color(0xFF9DB1CC).withValues(alpha: 0.55)
      ..style = PaintingStyle.fill;
    for (final dot in rawDots) {
      final o = toOffset(dot.key, dot.value);
      canvas.drawCircle(o, 2.5, rawPaint);
    }

    // ── 월평균 라인 ────────────────────────────────────────────────────────
    final avgOffsets = monthlyAvgs.map((e) => toOffset(e.key, e.value)).toList();

    // 채우기 영역 (그라디언트)
    final fillPath = Path()
      ..moveTo(avgOffsets.first.dx, avgOffsets.first.dy);
    for (int i = 1; i < avgOffsets.length; i++) {
      fillPath.lineTo(avgOffsets[i].dx, avgOffsets[i].dy);
    }
    fillPath
      ..lineTo(avgOffsets.last.dx, topPad + chartH)
      ..lineTo(avgOffsets.first.dx, topPad + chartH)
      ..close();
    canvas.drawPath(
      fillPath,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            kSecondary.withValues(alpha: 0.20),
            kSecondary.withValues(alpha: 0.0),
          ],
        ).createShader(Rect.fromLTWH(leftPad, topPad, chartW, chartH)),
    );

    // 평균 선
    final linePath = Path()
      ..moveTo(avgOffsets.first.dx, avgOffsets.first.dy);
    for (int i = 1; i < avgOffsets.length; i++) {
      linePath.lineTo(avgOffsets[i].dx, avgOffsets[i].dy);
    }
    canvas.drawPath(
      linePath,
      Paint()
        ..color = kSecondary
        ..strokeWidth = 2.0
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round,
    );

    // 월평균 점 (흰 테두리 + 파란 중심)
    for (final o in avgOffsets) {
      canvas.drawCircle(o, 4.0, Paint()..color = Colors.white);
      canvas.drawCircle(o, 2.8, Paint()..color = kSecondary);
    }
  }

  String _priceLabel(int price) {
    final eok = price ~/ 10000;
    final man = (price % 10000 + 500) ~/ 1000; // 천만 단위 반올림
    if (eok > 0 && man > 0) return '$eok억\n$man천';
    if (eok > 0) return '$eok억';
    return '${(price + 500) ~/ 1000}천만';
  }

  @override
  bool shouldRepaint(_PriceChartPainter old) =>
      old.monthlyAvgs != monthlyAvgs || old.rawDots != rawDots;
}

// ─────────────────────────────────────────────────────────────────────────────
// 시세 탭 필터 드롭다운 (연도/평형 공용)
// ─────────────────────────────────────────────────────────────────────────────

class _FilterDropdown<T> extends StatelessWidget {
  const _FilterDropdown({
    required this.value,
    required this.hint,
    required this.items,
    required this.label,
    required this.onChanged,
    this.enabled = true,
  });

  final T value;
  final String hint;
  final List<T> items;
  final String Function(T) label;
  final void Function(T) onChanged;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 36,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: kBorderColor),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<T>(
          value: value,
          hint: Text(hint,
              style: const TextStyle(fontSize: 13, color: kTextMuted)),
          isDense: true,
          icon: const Icon(Icons.keyboard_arrow_down_rounded,
              size: 18, color: kTextMuted),
          style: const TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w600,
            color: kTextDark,
          ),
          items: items
              .map((v) => DropdownMenuItem<T>(
                    value: v,
                    child: Text(label(v)),
                  ))
              .toList(),
          onChanged: enabled ? (T? v) { if (v != null || null is T) onChanged(v as T); } : null,
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// 거래 카드
// ─────────────────────────────────────────────────────────────────────────────

class _TradeCard extends StatelessWidget {
  const _TradeCard({required this.record});
  final AptTradeRecord record;

  @override
  Widget build(BuildContext context) {
    final pyeong = (record.area / 3.30579).round();
    return Container(
      margin: const EdgeInsets.only(bottom: 1),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
      decoration: const BoxDecoration(
        border: Border(
          bottom: BorderSide(color: Color(0xFFF0F2F5), width: 1),
        ),
      ),
      child: Row(
        children: [
          // 날짜
          SizedBox(
            width: 58,
            child: Text(
              record.dealDateStr,
              style: const TextStyle(fontSize: 12, color: kTextMuted),
            ),
          ),
          // 층수
          SizedBox(
            width: 34,
            child: Text(
              '${record.floor > 0 ? record.floor : '-'}층',
              style: const TextStyle(fontSize: 12, color: kTextMuted),
              textAlign: TextAlign.center,
            ),
          ),
          // 평형 + 면적
          Expanded(
            child: Text(
              '$pyeong평  ${record.area.toStringAsFixed(1)}㎡',
              style: const TextStyle(fontSize: 12, color: kTextMuted),
            ),
          ),
          // 가격 (우측, 강조)
          Text(
            record.priceLabel,
            style: const TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w700,
              color: kTextDark,
            ),
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// 탭 3: 임장노트
// ─────────────────────────────────────────────────────────────────────────────

class _ImjangNotesTab extends StatelessWidget {
  const _ImjangNotesTab({
    required this.label,
    required this.reviewCtrl,
    required this.pendingMedia,
    required this.isSaving,
    required this.canSubmit,
    required this.onPickImages,
    required this.onSubmit,
    required this.onRemoveMedia,
    required this.onTextChanged,
  });

  final String label;
  final TextEditingController reviewCtrl;
  final List<XFile> pendingMedia;
  final bool isSaving, canSubmit;
  final VoidCallback onPickImages, onSubmit, onTextChanged;
  final void Function(int) onRemoveMedia;

  @override
  Widget build(BuildContext context) {
    final bId = HouseLogService.buildingId(label);
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
          child: _QuickInputBox(
            controller: reviewCtrl,
            pendingMedia: pendingMedia,
            isSaving: isSaving,
            canSubmit: canSubmit,
            onPickImages: onPickImages,
            onSubmit: onSubmit,
            onRemoveMedia: onRemoveMedia,
            onTextChanged: onTextChanged,
          ),
        ),
        const SizedBox(height: 8),
        Expanded(
          child: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
            stream: ImjangService().logsStreamByBuilding(bId),
            builder: (ctx, snap) {
              if (snap.connectionState == ConnectionState.waiting) {
                return const Center(
                  child: CircularProgressIndicator(strokeWidth: 2),
                );
              }
              final docs = snap.data?.docs ?? [];
              if (docs.isEmpty) {
                return const _EmptyState(
                  icon: Icons.note_alt_outlined,
                  message: '첫 임장 기록을 남겨보세요!',
                );
              }
              return ListView.separated(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 4,
                ),
                itemCount: docs.length,
                separatorBuilder: (_, __) => const SizedBox(height: 8),
                itemBuilder: (ctx, i) {
                  final data = docs[i].data();
                  final mediaUrls =
                      List<String>.from(data['mediaUrls'] ?? []);
                  final text = (data['review'] ?? '') as String;
                  final createdAt =
                      (data['createdAt'] as Timestamp?)?.toDate() ??
                      DateTime.now();
                  return GestureDetector(
                    onTap: () => Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) => ImjangNoteDetailScreen(
                          text: text,
                          mediaUrls: mediaUrls,
                          createdAt: createdAt,
                          docId: docs[i].id,
                          aptName: label,
                        ),
                      ),
                    ),
                    child: _NoteListItem(
                      text: text,
                      mediaUrls: mediaUrls,
                      createdAt: createdAt,
                    ),
                  );
                },
              );
            },
          ),
        ),
        SizedBox(height: MediaQuery.of(context).padding.bottom + 8),
      ],
    );
  }
}

class _NoteListItem extends StatelessWidget {
  const _NoteListItem({
    required this.text,
    required this.mediaUrls,
    required this.createdAt,
  });

  final String text;
  final List<String> mediaUrls;
  final DateTime createdAt;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: kBorderColor),
      ),
      child: Row(
        children: [
          // 썸네일
          ClipRRect(
            borderRadius: const BorderRadius.horizontal(
              left: Radius.circular(11),
            ),
            child: SizedBox(
              width: 80,
              height: 80,
              child: mediaUrls.isNotEmpty
                  ? CachedNetworkImage(
                      imageUrl: mediaUrls.first,
                      fit: BoxFit.cover,
                    )
                  : Container(
                      color: kPrimary.withValues(alpha: 0.06),
                      child: const Icon(
                        Icons.note_alt_outlined,
                        color: kPrimary,
                        size: 28,
                      ),
                    ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 4),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    text.isEmpty ? '(사진만 첨부)' : text,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 13,
                      color: kTextDark,
                      height: 1.4,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    _formatDate(createdAt),
                    style: const TextStyle(fontSize: 11, color: kTextMuted),
                  ),
                ],
              ),
            ),
          ),
          const Padding(
            padding: EdgeInsets.only(right: 12),
            child: Icon(
              Icons.chevron_right_rounded,
              color: kTextMuted,
              size: 20,
            ),
          ),
        ],
      ),
    );
  }

  String _formatDate(DateTime dt) =>
      '${dt.year}.${dt.month.toString().padLeft(2, '0')}.${dt.day.toString().padLeft(2, '0')}';
}

// ─────────────────────────────────────────────────────────────────────────────
// 임장노트 빠른 입력 박스
// ─────────────────────────────────────────────────────────────────────────────

class _QuickInputBox extends StatelessWidget {
  const _QuickInputBox({
    required this.controller,
    required this.pendingMedia,
    required this.isSaving,
    required this.canSubmit,
    required this.onPickImages,
    required this.onSubmit,
    required this.onRemoveMedia,
    required this.onTextChanged,
  });

  final TextEditingController controller;
  final List<XFile> pendingMedia;
  final bool isSaving, canSubmit;
  final VoidCallback onPickImages, onSubmit, onTextChanged;
  final void Function(int) onRemoveMedia;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: _kCardBg,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: kBorderColor),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const SizedBox(width: 14),
              Expanded(
                child: TextField(
                  controller: controller,
                  onChanged: (_) => onTextChanged(),
                  maxLines: 5,
                  minLines: 1,
                  enabled: !isSaving,
                  style: const TextStyle(
                    fontSize: 14,
                    color: kTextDark,
                    height: 1.4,
                  ),
                  decoration: InputDecoration(
                    hintText: '현장 느낌을 한 줄로 남겨보세요...',
                    hintStyle: TextStyle(
                      fontSize: 14,
                      color: Colors.grey.shade400,
                    ),
                    border: InputBorder.none,
                    isDense: true,
                    contentPadding: const EdgeInsets.symmetric(vertical: 14),
                  ),
                ),
              ),
              IconButton(
                onPressed: isSaving ? null : onPickImages,
                icon: Icon(
                  Icons.photo_library_outlined,
                  size: 22,
                  color: isSaving
                      ? Colors.grey.shade300
                      : kPrimary.withValues(alpha: 0.65),
                ),
              ),
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: SizedBox(
                  height: 34,
                  child: ElevatedButton(
                    onPressed: canSubmit ? onSubmit : null,
                    style: ElevatedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(horizontal: 14),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10),
                      ),
                      minimumSize: Size.zero,
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                    child: isSaving
                        ? const SizedBox(
                            width: 14,
                            height: 14,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: Colors.white,
                            ),
                          )
                        : Text(
                            '등록',
                            style: TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w700,
                              color:
                                  canSubmit ? Colors.white : Colors.grey.shade500,
                            ),
                          ),
                  ),
                ),
              ),
            ],
          ),
          if (pendingMedia.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 4, 12, 10),
              child: SizedBox(
                height: 72,
                child: ListView.builder(
                  scrollDirection: Axis.horizontal,
                  itemCount: pendingMedia.length,
                  itemBuilder: (_, i) => Stack(
                    children: [
                      Container(
                        width: 64,
                        height: 64,
                        margin: const EdgeInsets.only(right: 8),
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(color: kBorderColor),
                        ),
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(7),
                          child: Image.file(
                            File(pendingMedia[i].path),
                            fit: BoxFit.cover,
                          ),
                        ),
                      ),
                      Positioned(
                        top: 0,
                        right: 6,
                        child: GestureDetector(
                          onTap: isSaving ? null : () => onRemoveMedia(i),
                          child: Container(
                            width: 18,
                            height: 18,
                            decoration: const BoxDecoration(
                              color: Colors.black54,
                              shape: BoxShape.circle,
                            ),
                            child: const Icon(
                              Icons.close,
                              color: Colors.white,
                              size: 11,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// 공통 헬퍼 위젯
// ─────────────────────────────────────────────────────────────────────────────

class _InfoCard extends StatelessWidget {
  const _InfoCard({required this.children});
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: kBorderColor),
      ),
      child: Column(
        children: children.asMap().entries.map((e) {
          final isLast = e.key == children.length - 1;
          return Column(
            children: [
              e.value,
              if (!isLast)
                const Divider(
                  height: 1,
                  thickness: 1,
                  indent: 16,
                  endIndent: 16,
                ),
            ],
          );
        }).toList(),
      ),
    );
  }
}

class _InfoRow extends StatelessWidget {
  const _InfoRow({required this.label, required this.value});
  final String label, value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 80,
            child: Text(
              label,
              style: const TextStyle(
                fontSize: 13,
                color: kTextMuted,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: const TextStyle(
                fontSize: 13,
                color: kTextDark,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _LoadingRow extends StatelessWidget {
  const _LoadingRow();

  @override
  Widget build(BuildContext context) {
    return const Padding(
      padding: EdgeInsets.all(16),
      child: Center(
        child: SizedBox(
          width: 18,
          height: 18,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.icon, required this.message});
  final IconData icon;
  final String message;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(icon, size: 40, color: Colors.grey.shade300),
          const SizedBox(height: 10),
          Text(
            message,
            style: TextStyle(fontSize: 13, color: Colors.grey.shade400),
          ),
        ],
      ),
    );
  }
}


// ─────────────────────────────────────────────────────────────────────────────
// 마커 가격 데이터 모델
// ─────────────────────────────────────────────────────────────────────────────

class _MarkerPrice {
  const _MarkerPrice({required this.priceLabel, required this.pyeongLabel});
  final String priceLabel; // "8.5억"
  final String pyeongLabel; // "24평"
}

// ─────────────────────────────────────────────────────────────────────────────
// 말풍선 마커 위젯 (네이비 카드 + 흰 텍스트)
// ─────────────────────────────────────────────────────────────────────────────

/// [레이아웃]  setAnchor(0.5, 1.0) 필수.
///
///   ┌─────────────┐
///   │    8.5억    │  ← 흰색 bold 15sp
///   │    24평     │  ← 반투명 흰색 10sp
///   └──────┬──────┘
///          ▼ 포인터
class _AptPriceBubble extends StatelessWidget {
  const _AptPriceBubble({
    required this.priceLabel,
    required this.pyeongLabel,
  });

  final String priceLabel;
  final String pyeongLabel;

  static const _kPointerH = 7.0;

  @override
  Widget build(BuildContext context) {
    final hasPrice = priceLabel.isNotEmpty;
    final hasPyeong = pyeongLabel.isNotEmpty;

    return CustomPaint(
      painter: const _BubblePainter(),
      child: Padding(
        padding: EdgeInsets.fromLTRB(10, 6, 10, 6 + _kPointerH),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            // 가격 (크게)
            Text(
              hasPrice ? priceLabel : '시세없음',
              style: TextStyle(
                fontSize: hasPrice ? 15 : 11,
                fontWeight: FontWeight.w800,
                color: Colors.white,
                height: 1.15,
                letterSpacing: -0.4,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            // 평수 (작게, 한 줄 간격)
            if (hasPyeong) ...[
              const SizedBox(height: 5),
              Text(
                pyeongLabel,
                style: TextStyle(
                  fontSize: 10,
                  fontWeight: FontWeight.w600,
                  color: Colors.white.withOpacity(0.85),
                  height: 1.1,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// 네이비 말풍선 CustomPainter.
/// kPrimary 그라디언트 본체 + 하단 삼각 포인터 + 드롭섀도우.
class _BubblePainter extends CustomPainter {
  const _BubblePainter();

  static const _radius = 10.0;
  static const _pointerH = 7.0;
  static const _pointerW = 12.0;

  @override
  void paint(Canvas canvas, Size size) {
    final bodyH = size.height - _pointerH;
    final cx = size.width / 2;

    final path = Path()
      ..moveTo(_radius, 0)
      ..lineTo(size.width - _radius, 0)
      ..arcToPoint(Offset(size.width, _radius),
          radius: const Radius.circular(_radius))
      ..lineTo(size.width, bodyH - _radius)
      ..arcToPoint(Offset(size.width - _radius, bodyH),
          radius: const Radius.circular(_radius))
      ..lineTo(cx + _pointerW / 2, bodyH)
      ..lineTo(cx, size.height)
      ..lineTo(cx - _pointerW / 2, bodyH)
      ..lineTo(_radius, bodyH)
      ..arcToPoint(Offset(0, bodyH - _radius),
          radius: const Radius.circular(_radius))
      ..lineTo(0, _radius)
      ..arcToPoint(const Offset(_radius, 0),
          radius: const Radius.circular(_radius))
      ..close();

    // 드롭섀도우
    canvas.drawShadow(path, const Color(0x66D84315), 5, true);

    // 그라디언트 채우기
    final rect = Rect.fromLTWH(0, 0, size.width, bodyH);
    canvas.drawPath(
      path,
      Paint()
        ..shader = const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0xFFFF7043), Color(0xFFE64A19)],
        ).createShader(rect)
        ..style = PaintingStyle.fill,
    );
  }

  @override
  bool shouldRepaint(_BubblePainter old) => false;
}
