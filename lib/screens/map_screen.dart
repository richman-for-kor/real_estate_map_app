import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:fl_chart/fl_chart.dart';
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
        kBackground,
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
import 'package:firebase_auth/firebase_auth.dart';

// ─── 카카오 로컬 API (키워드 장소 검색) 설정 ───────────────────────────────────
// ⚠️  아래 키를 카카오 디벨로퍼스(developers.kakao.com)에서 발급받은
//     [REST API 키]로 교체한 뒤 flutter run 하세요.
const _kKakaoSearchUrl = 'https://dapi.kakao.com/v2/local/search/keyword.json';

// ─── 색상 상수 ─────────────────────────────────────────────────────────────────
const _kPageBg = Color(0xFFF2F2F7);
const _kCardBg = Colors.white;
const _kRed = Color(0xFFE53935);
const _kGreen = Color(0xFF2E7D32);
const _kOrange = Color(0xFFE65100);

// ─── 차트 Mock 데이터 ─────────────────────────────────────────────────────────
const _kSaleSpots = [
  FlSpot(1, 11.8),
  FlSpot(2, 12.0),
  FlSpot(3, 12.2),
  FlSpot(4, 12.4),
  FlSpot(5, 12.5),
  FlSpot(6, 12.7),
  FlSpot(7, 13.0),
  FlSpot(8, 13.1),
  FlSpot(9, 13.3),
  FlSpot(10, 13.5),
  FlSpot(11, 13.7),
  FlSpot(12, 13.8),
];
const _kJeonseSpots = [
  FlSpot(1, 8.5),
  FlSpot(2, 8.7),
  FlSpot(3, 8.9),
  FlSpot(4, 9.0),
  FlSpot(5, 9.2),
  FlSpot(6, 9.4),
  FlSpot(7, 9.6),
  FlSpot(8, 9.7),
  FlSpot(9, 9.8),
  FlSpot(10, 10.0),
  FlSpot(11, 10.1),
  FlSpot(12, 10.2),
];

// ─── 평형별 투자 Mock 데이터 ──────────────────────────────────────────────────
class _UnitData {
  const _UnitData({
    required this.salePrice,
    required this.jeonsePrice,
    required this.gap,
    required this.jeonseRate,
    required this.highPrice,
    required this.saleSpots,
    required this.jeonseSpots,
    required this.chartMinY,
    required this.chartMaxY,
  });
  final String salePrice, jeonsePrice, gap, jeonseRate, highPrice;
  final List<FlSpot> saleSpots, jeonseSpots;
  final double chartMinY, chartMaxY;
}

const _kUnitDataMap = <String, _UnitData>{
  '15평': _UnitData(
    salePrice: '8.5억',
    jeonsePrice: '6.8억',
    gap: '1.7억',
    jeonseRate: '80%',
    highPrice: '9.2억',
    chartMinY: 4.0,
    chartMaxY: 11.0,
    saleSpots: [FlSpot(1, 7.2), FlSpot(6, 7.9), FlSpot(12, 8.5)],
    jeonseSpots: [FlSpot(1, 5.8), FlSpot(6, 6.4), FlSpot(12, 6.8)],
  ),
  '24평': _UnitData(
    salePrice: '13.5억',
    jeonsePrice: '10.3억',
    gap: '3.2억',
    jeonseRate: '76%',
    highPrice: '15.8억',
    chartMinY: 7.0,
    chartMaxY: 16.0,
    saleSpots: _kSaleSpots,
    jeonseSpots: _kJeonseSpots,
  ),
  '33평': _UnitData(
    salePrice: '19.8억',
    jeonsePrice: '14.2억',
    gap: '5.6억',
    jeonseRate: '72%',
    highPrice: '22.5억',
    chartMinY: 10.0,
    chartMaxY: 24.0,
    saleSpots: [FlSpot(1, 16.5), FlSpot(6, 17.9), FlSpot(12, 19.8)],
    jeonseSpots: [FlSpot(1, 12.0), FlSpot(6, 13.2), FlSpot(12, 14.2)],
  ),
};

// ─────────────────────────────────────────────────────────────────────────────
// MapScreen
// ─────────────────────────────────────────────────────────────────────────────

class MapScreen extends StatefulWidget {
  const MapScreen({super.key});

  @override
  State<MapScreen> createState() => _MapScreenState();
}

class _MapScreenState extends State<MapScreen> {
  NaverMapController? _mapController;
  final _searchController = TextEditingController();

  // 검색 상태 관리
  Timer? _debounce;
  bool _isSearching = false;
  bool _showDropdown = false;
  List<dynamic> _searchResults = [];

  bool _isLocationLoading = false;
  bool _isMarkersLoading = false; // 아파트 마커 데이터 로딩 중 여부

  String? _currentBjdCode; // 현재 카메라 중심의 법정동 코드

  NMarker? _searchMarker;
  final List<NMarker> _aptMarkers = [];

  // 지도 초기 위치 (분당 미금역) 에 해당하는 법정동코드.
  // onCameraIdle + 역지오코딩 구현 시 동적으로 교체됩니다.
  // ⚠️  공동주택 단지 목록 API는 10자리 법정동코드 필수.
  //     5자리(시군구) 코드는 HTTP 500 또는 빈 결과 반환.
  static const _kInitialBjdCode = '4113510300'; // 경기 성남시 분당구 수내1동

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
  void dispose() {
    _debounce?.cancel();
    _searchController.dispose();
    super.dispose();
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

  void _onMapReady(NaverMapController controller) {
    _mapController = controller;
    _tryActivateLocationIfGranted();
    _currentBjdCode = _kInitialBjdCode;
    _renderAptMarkers(_kInitialBjdCode);
  }

  Future<void> _onCameraIdle() async {
    // 마커 로딩 중엔 _currentBjdCode 갱신 자체를 막아 잘못된 중복 방지를 예방
    if (_mapController == null || _isMarkersLoading) return;
    final position = await _mapController!.getCameraPosition();
    final lat = position.target.latitude;
    final lng = position.target.longitude;
    final bjdCode = await _getBjdCodeFromCoords(lat, lng);
    if (bjdCode == null || bjdCode == _currentBjdCode) return;
    _currentBjdCode = bjdCode;
    _renderAptMarkers(bjdCode);
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
      final res = await http.get(
        uri,
        headers: {'Authorization': 'KakaoAK $kakaoKey'},
      );
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

  Future<void> _tryActivateLocationIfGranted() async {
    final permission = await Geolocator.checkPermission();
    if ((permission == LocationPermission.whileInUse ||
            permission == LocationPermission.always) &&
        _mapController != null &&
        mounted) {
      _mapController!.setLocationTrackingMode(NLocationTrackingMode.noFollow);
    }
  }

  // ── 말풍선 마커 아이콘 생성 ──────────────────────────────────────────────
  // NOverlayImage.fromWidget()은 Flutter 위젯을 비트맵으로 렌더링.
  // 가격·면적 정보가 있으면 말풍선, 없으면 기본 핀 아이콘 사용.
  Future<NOverlayImage?> _buildMarkerIcon(ApartmentInfo apt) async {
    try {
      return await NOverlayImage.fromWidget(
        context: context,
        size: const Size(72, 52),
        widget: _AptPriceBubble(priceLabel: apt.kaptName, areaLabel: ''),
      );
    } catch (e) {
      debugPrint('[MapScreen] 마커 아이콘 생성 실패 (${apt.kaptName}): $e');
      return null; // null → NaverMap 기본 마커 사용
    }
  }

  // ── 아파트 마커 일괄 렌더링 (Firebase Read-Through Cache) ─────────────────
  Future<void> _renderAptMarkers(String bjdCode) async {
    if (_mapController == null) return;
    if (_isMarkersLoading) return;

    setState(() => _isMarkersLoading = true);

    // 기존 마커 일괄 제거
    if (_aptMarkers.isNotEmpty) {
      await _mapController!.clearOverlays(type: NOverlayType.marker);
      _aptMarkers.clear();
    }

    try {
      final apts = await ApartmentRepository.instance.getApartmentsByBjdCode(
        bjdCode,
      );

      if (!mounted) return;

      // ── 1단계: 마커 객체 + 아이콘 순차 생성 (UI 프리징 방어) ─────────────
      // Future.wait으로 수백 개 NOverlayImage.fromWidget을 동시 호출하면
      // UI 스레드가 블로킹됩니다. 순차 for 루프로 변경하여 렌더링 병목을 방지합니다.
      final validApts = apts.where((a) => a.hasValidCoords).toList();
      final markers = <NMarker>[];
      for (final apt in validApts) {
        // 장시간 비동기(API 호출 + 아이콘 렌더링) 중 위젯 해제 방어
        if (!mounted) return;

        final pos = NLatLng(apt.lat, apt.lng);
        final marker = NMarker(id: apt.kaptCode, position: pos);

        final icon = await _buildMarkerIcon(apt);
        if (icon != null) {
          marker.setIcon(icon);
          marker.setAnchor(const NPoint(0.5, 1.0));
        }

        marker.setCaption(
          NOverlayCaption(
            text: apt.kaptName,
            textSize: 10,
            color: kTextMuted,
            haloColor: Colors.white,
          ),
        );

        marker.setOnTapListener((_) {
          _showPropertyInfoSheet(
            pos,
            apt.kaptName,
            lawdCd: apt.bjdCode.length >= 5
                ? apt.bjdCode.substring(0, 5)
                : apt.bjdCode,
            apt: apt,
          );
          return true;
        });

        markers.add(marker);
      }

      // await 이후 컨트롤러가 무효화될 수 있으므로 재확인
      if (!mounted || _mapController == null) return;

      // ── 2단계: addOverlayAll()로 한 번에 지도에 추가 ──────────────────────
      await _mapController!.addOverlayAll(markers.toSet());
      _aptMarkers.addAll(markers);

      debugPrint('[MapScreen] 마커 렌더링 완료 — ${_aptMarkers.length}개');
    } catch (e) {
      debugPrint('[MapScreen] 마커 렌더링 오류: $e');
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('단지 정보를 불러오지 못했습니다.')));
      }
    } finally {
      if (mounted) setState(() => _isMarkersLoading = false);
    }
  }

  void _onMapTapped(NPoint point, NLatLng latLng) {
    // 맵 빈 곳 터치 시 드롭다운/키보드 닫기만 처리.
    // 바텀시트는 아파트 마커 탭 리스너(_renderAptMarkers)에서 열립니다.
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

    // 지번주소가 없으면 도로명주소 사용
    final address = (place['road_address_name'] as String).isNotEmpty
        ? place['road_address_name']
        : place['address_name'];

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

  void _showPropertyInfoSheet(
    NLatLng pos,
    String label, {
    String lawdCd = '41135',
    ApartmentInfo? apt,
  }) {
    showModalBottomSheet(
      context: context,
      useRootNavigator: true,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => DraggableScrollableSheet(
        initialChildSize: 0.4,
        minChildSize: 0.3,
        maxChildSize: 0.9,
        expand: false,
        snap: true,
        snapSizes: const [0.4, 0.65, 0.9],
        builder: (_, scrollCtrl) => _PropertyInfoSheet(
          position: pos,
          label: label,
          lawdCd: lawdCd,
          dealYmd: '202511',
          scrollController: scrollCtrl,
          apt: apt,
        ),
      ),
    );
  }

  // ── GPS 기능 ────────────────────────────────────────────────────────────
  Future<void> _requestLocationAndTrack() async {
    if (_isLocationLoading) return;
    setState(() => _isLocationLoading = true);

    try {
      final serviceEnabled = await Geolocator.isLocationServiceEnabled();
      if (!serviceEnabled) return;

      var permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
        if (permission == LocationPermission.denied) return;
      }
      if (permission == LocationPermission.deniedForever) {
        await openAppSettings();
        return;
      }

      _mapController?.setLocationTrackingMode(NLocationTrackingMode.follow);
    } finally {
      if (mounted) setState(() => _isLocationLoading = false);
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
// 부동산 정보 바텀시트 — 하단 코드는 기존과 완벽히 동일합니다.
// ─────────────────────────────────────────────────────────────────────────────

class _PropertyInfoSheet extends StatefulWidget {
  const _PropertyInfoSheet({
    required this.position,
    required this.label,
    required this.lawdCd,
    required this.dealYmd,
    required this.scrollController,
    this.apt,
  });

  final NLatLng position;
  final String label, lawdCd, dealYmd;
  final ScrollController scrollController;
  final ApartmentInfo? apt;

  @override
  State<_PropertyInfoSheet> createState() => _PropertyInfoSheetState();
}

class _PropertyInfoSheetState extends State<_PropertyInfoSheet> {
  late final Future<AptTradeData> _dataFuture;
  final _reviewCtrl = TextEditingController();
  final _picker = ImagePicker();
  final _service = HouseLogService();
  final _favService = FavoriteService();
  final List<XFile> _pendingMedia = [];
  bool _isSaving = false;
  String _selectedUnit = '24평';

  /// 찜 문서 ID: kaptCode 우선, 없으면 단지명을 사용.
  String get _favoriteId {
    final code = widget.apt?.kaptCode ?? '';
    return code.isNotEmpty ? code : widget.label;
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
          SnackBar(content: Text('오류: $e'), margin: const EdgeInsets.all(16)),
        );
      }
    }
  }

  @override
  void initState() {
    super.initState();
    _dataFuture = const PublicDataService().fetchAptTrades(
      lawdCd: widget.lawdCd,
      dealYmd: widget.dealYmd,
    );
  }

  @override
  void dispose() {
    _reviewCtrl.dispose();
    super.dispose();
  }

  bool get _canSubmit =>
      (_reviewCtrl.text.trim().isNotEmpty || _pendingMedia.isNotEmpty) &&
      !_isSaving;

  Future<void> _pickImages() async {
    if (_isSaving) return;
    final picked = await _picker.pickMultiImage(imageQuality: 85);
    if (picked.isNotEmpty && mounted)
      setState(() => _pendingMedia.addAll(picked));
  }

  Future<void> _submit() async {
    if (!_canSubmit) return;
    if (!_service.isAuthenticated) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('로그인 후 임장 기록을 남길 수 있습니다.')));
      return;
    }
    setState(() => _isSaving = true);
    try {
      await _service.saveLog(
        buildingId: HouseLogService.buildingId(widget.label),
        text: _reviewCtrl.text.trim(),
        imageFiles: _pendingMedia.map((f) => File(f.path)).toList(),
      );
      if (mounted) {
        setState(() {
          _reviewCtrl.clear();
          _pendingMedia.clear();
          _isSaving = false;
        });
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('임장 기록이 등록되었습니다.')));
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
    return Container(
      clipBehavior: Clip.antiAlias,
      decoration: const BoxDecoration(
        color: _kPageBg,
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      child: Column(
        children: [
          Container(
            margin: const EdgeInsets.only(top: 12, bottom: 8),
            width: 36,
            height: 4,
            decoration: BoxDecoration(
              color: Colors.grey.shade300,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          Expanded(
            child: CustomScrollView(
              controller: widget.scrollController,
              slivers: [
                SliverPadding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  sliver: SliverList(
                    delegate: SliverChildListDelegate([
                      const SizedBox(height: 4),
                      _buildComplexHeader(),
                      const SizedBox(height: 12),
                      _buildQuickInputBox(),
                      const SizedBox(height: 16),
                      _buildHistorySection(),
                      const SizedBox(height: 16),
                      _buildUnitTabs(),
                      const SizedBox(height: 12),
                      const Text(
                        '시세 & 투자 지표',
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      const SizedBox(height: 8),
                      _PriceOverviewCard(data: _kUnitDataMap[_selectedUnit]!),
                      const SizedBox(height: 12),
                      _PriceTrendChartCard(data: _kUnitDataMap[_selectedUnit]!),
                      const SizedBox(height: 16),
                      const Text(
                        '단지 정보',
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      const SizedBox(height: 8),
                      const _BuildingInfoCard(),
                      const SizedBox(height: 16),
                      const Text(
                        '학군 & 입지',
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      const SizedBox(height: 8),
                      const _SchoolLocationCard(),
                      const SizedBox(height: 16),
                      const _DongBreakdownCard(),
                      const SizedBox(height: 16),
                      _buildTradeSection(),
                      SizedBox(
                        height: MediaQuery.of(context).padding.bottom + 24,
                      ),
                    ]),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildComplexHeader() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
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
                widget.label,
                style: const TextStyle(fontSize: 11, color: kTextMuted),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            StreamBuilder<bool>(
              stream: _favService.isFavoriteStream(_favoriteId),
              builder: (context, snap) {
                final isFav = snap.data ?? false;
                return GestureDetector(
                  onTap: () => _toggleFavorite(isFav),
                  child: Padding(
                    padding: const EdgeInsets.only(left: 8),
                    child: Icon(
                      isFav
                          ? Icons.favorite_rounded
                          : Icons.favorite_outline_rounded,
                      color: isFav
                          ? const Color(0xFFE53935)
                          : Colors.grey.shade400,
                      size: 26,
                    ),
                  ),
                );
              },
            ),
          ],
        ),
        const SizedBox(height: 8),
        Text(
          widget.label,
          style: const TextStyle(
            fontSize: 26,
            fontWeight: FontWeight.w800,
            color: kTextDark,
            letterSpacing: -0.9,
            height: 1.1,
          ),
        ),
      ],
    );
  }

  Widget _buildQuickInputBox() {
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
                  controller: _reviewCtrl,
                  onChanged: (_) => setState(() {}),
                  maxLines: null,
                  minLines: 1,
                  enabled: !_isSaving,
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
                onPressed: _isSaving ? null : _pickImages,
                icon: Icon(
                  Icons.photo_library_outlined,
                  size: 22,
                  color: _isSaving
                      ? Colors.grey.shade300
                      : kPrimary.withValues(alpha: 0.65),
                ),
              ),
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: SizedBox(
                  height: 34,
                  child: ElevatedButton(
                    onPressed: _canSubmit ? _submit : null,
                    style: ElevatedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(horizontal: 14),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10),
                      ),
                      minimumSize: Size.zero,
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                    child: _isSaving
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
                              color: _canSubmit
                                  ? Colors.white
                                  : Colors.grey.shade500,
                            ),
                          ),
                  ),
                ),
              ),
            ],
          ),
          if (_pendingMedia.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 4, 12, 10),
              child: SizedBox(
                height: 72,
                child: ListView.builder(
                  scrollDirection: Axis.horizontal,
                  itemCount: _pendingMedia.length,
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
                            File(_pendingMedia[i].path),
                            fit: BoxFit.cover,
                          ),
                        ),
                      ),
                      Positioned(
                        top: 0,
                        right: 6,
                        child: GestureDetector(
                          onTap: _isSaving
                              ? null
                              : () => setState(() => _pendingMedia.removeAt(i)),
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

  Widget _buildHistorySection() {
    final bId = HouseLogService.buildingId(widget.label);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          '내 임장 기록',
          style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800),
        ),
        const SizedBox(height: 8),
        SizedBox(
          height: 108,
          child: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
            stream: _service.logsStream(bId),
            builder: (ctx, snap) {
              if (snap.connectionState == ConnectionState.waiting)
                return const Center(child: CircularProgressIndicator());
              final docs = snap.data?.docs ?? [];
              if (docs.isEmpty)
                return const Center(
                  child: Text(
                    '첫 임장 기록을 남겨보세요!',
                    style: TextStyle(color: kTextMuted),
                  ),
                );
              return ListView.builder(
                scrollDirection: Axis.horizontal,
                itemCount: docs.length,
                itemBuilder: (ctx, i) {
                  final data = docs[i].data();
                  return Container(
                    width: 130,
                    margin: const EdgeInsets.only(right: 10),
                    decoration: BoxDecoration(
                      color: _kCardBg,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: kBorderColor),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        ClipRRect(
                          borderRadius: const BorderRadius.vertical(
                            top: Radius.circular(11),
                          ),
                          child: SizedBox(
                            height: 60,
                            width: double.infinity,
                            child:
                                (data['mediaUrls'] as List?)?.isNotEmpty == true
                                ? CachedNetworkImage(
                                    imageUrl: data['mediaUrls'][0],
                                    fit: BoxFit.cover,
                                  )
                                : Container(
                                    color: kPrimary.withValues(alpha: 0.06),
                                    child: const Icon(
                                      Icons.note_alt_outlined,
                                      color: kPrimary,
                                    ),
                                  ),
                          ),
                        ),
                        Padding(
                          padding: const EdgeInsets.all(8),
                          child: Text(
                            data['text'] ?? '',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontSize: 11),
                          ),
                        ),
                      ],
                    ),
                  );
                },
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _buildUnitTabs() {
    const units = ['15평', '24평', '33평'];
    return Row(
      children: units.map((unit) {
        final selected = _selectedUnit == unit;
        return Padding(
          padding: const EdgeInsets.only(right: 8),
          child: GestureDetector(
            onTap: () => setState(() => _selectedUnit = unit),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 200),
              curve: Curves.easeInOut,
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 9),
              decoration: BoxDecoration(
                color: selected ? kPrimary : Colors.white,
                borderRadius: BorderRadius.circular(22),
                border: Border.all(
                  color: selected ? kPrimary : kBorderColor,
                  width: 1.2,
                ),
                boxShadow: selected
                    ? [
                        BoxShadow(
                          color: kPrimary.withValues(alpha: 0.28),
                          blurRadius: 10,
                          offset: const Offset(0, 4),
                        ),
                      ]
                    : [],
              ),
              child: AnimatedDefaultTextStyle(
                duration: const Duration(milliseconds: 200),
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                  color: selected ? Colors.white : kTextMuted,
                ),
                child: Text(unit),
              ),
            ),
          ),
        );
      }).toList(),
    );
  }

  // ── 로딩/에러/빈 결과 공용 Empty-State ────────────────────────────────────
  Widget _emptyTradeState({required IconData icon, required String message}) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 32),
      width: double.infinity,
      decoration: BoxDecoration(
        color: Colors.grey.shade50,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: kBorderColor),
      ),
      child: Column(
        children: [
          Icon(icon, size: 36, color: Colors.grey.shade300),
          const SizedBox(height: 10),
          Text(
            message,
            style: TextStyle(fontSize: 13, color: Colors.grey.shade400),
          ),
        ],
      ),
    );
  }

  Widget _buildTradeSection() {
    return FutureBuilder<AptTradeData>(
      future: _dataFuture,
      builder: (ctx, snap) {
        // ── 로딩 ────────────────────────────────────────────────────────────
        if (snap.connectionState == ConnectionState.waiting) {
          return const SizedBox(
            height: 80,
            child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
          );
        }
        // ── API 오류 ─────────────────────────────────────────────────────────
        if (snap.hasError || !snap.hasData) {
          return _emptyTradeState(
            icon: Icons.cloud_off_outlined,
            message: '실거래가를 불러오지 못했습니다.',
          );
        }
        // ── RangeError 완벽 방어: 결과 0건 ──────────────────────────────────
        if (snap.data!.records.isEmpty) {
          return _emptyTradeState(
            icon: Icons.info_outline,
            message: '해당 월의 실거래 내역이 없습니다.',
          );
        }
        // ── 실거래 카드 목록 ─────────────────────────────────────────────────
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              '최근 실거래가',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 10),
            ...snap.data!.records.map(
              (r) => Container(
                margin: const EdgeInsets.only(bottom: 8),
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 12,
                ),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: kBorderColor),
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            r.complexName,
                            style: const TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w700,
                              color: kTextDark,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            '${r.area}㎡  ·  ${r.floor}층',
                            style: const TextStyle(
                              fontSize: 12,
                              color: kTextMuted,
                            ),
                          ),
                        ],
                      ),
                    ),
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        Text(
                          r.priceLabel,
                          style: const TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w800,
                            color: kTextDark,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          r.dealDateStr,
                          style: const TextStyle(
                            fontSize: 11,
                            color: kTextMuted,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

// 나머지 UI 컴포넌트들 (기존 코드에서 분리된 부분)
class _PriceOverviewCard extends StatelessWidget {
  const _PriceOverviewCard({required this.data});
  final _UnitData data;
  @override
  Widget build(BuildContext context) => Container(
    color: Colors.white,
    padding: const EdgeInsets.all(16),
    child: Text('매매가: ${data.salePrice} / 전세가율: ${data.jeonseRate}'),
  );
}

class _PriceTrendChartCard extends StatelessWidget {
  const _PriceTrendChartCard({required this.data});
  final _UnitData data;

  Widget _legendItem(Color color, String label, {required bool dashed}) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          width: 20,
          height: 10,
          child: CustomPaint(
            painter: _DashLinePainter(color: color, dashed: dashed),
          ),
        ),
        const SizedBox(width: 5),
        Text(
          label,
          style: const TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w600,
            color: kTextMuted,
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(8, 16, 16, 10),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: kBorderColor),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ── 범례 ───────────────────────────────────────────────────────────
          Padding(
            padding: const EdgeInsets.only(left: 8),
            child: Row(
              children: [
                _legendItem(kPrimary, '매매가', dashed: false),
                const SizedBox(width: 18),
                _legendItem(kSecondary, '전세가', dashed: true),
              ],
            ),
          ),
          const SizedBox(height: 14),
          // ── LineChart ──────────────────────────────────────────────────────
          SizedBox(
            height: 160,
            child: LineChart(
              LineChartData(
                minX: 1,
                maxX: 12,
                minY: data.chartMinY,
                maxY: data.chartMaxY,
                clipData: const FlClipData.all(),
                gridData: FlGridData(
                  show: true,
                  drawVerticalLine: false,
                  horizontalInterval: (data.chartMaxY - data.chartMinY) / 4,
                  getDrawingHorizontalLine: (_) =>
                      FlLine(color: Colors.grey.shade100, strokeWidth: 1),
                ),
                borderData: FlBorderData(show: false),
                titlesData: FlTitlesData(
                  // ── Y축 (왼쪽) ─────────────────────────────────────────────
                  leftTitles: AxisTitles(
                    sideTitles: SideTitles(
                      showTitles: true,
                      reservedSize: 38,
                      interval: (data.chartMaxY - data.chartMinY) / 4,
                      getTitlesWidget: (value, meta) {
                        if (value == meta.min || value == meta.max) {
                          return const SizedBox.shrink();
                        }
                        return Text(
                          '${value.toStringAsFixed(0)}억',
                          style: TextStyle(
                            fontSize: 10,
                            color: Colors.grey.shade400,
                          ),
                          textAlign: TextAlign.right,
                        );
                      },
                    ),
                  ),
                  // ── X축 (아래) ─────────────────────────────────────────────
                  bottomTitles: AxisTitles(
                    sideTitles: SideTitles(
                      showTitles: true,
                      interval: 1,
                      getTitlesWidget: (value, meta) {
                        const visible = {1, 4, 7, 10, 12};
                        final v = value.toInt();
                        if (!visible.contains(v))
                          return const SizedBox.shrink();
                        return Padding(
                          padding: const EdgeInsets.only(top: 4),
                          child: Text(
                            '$v월',
                            style: TextStyle(
                              fontSize: 10,
                              color: Colors.grey.shade400,
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                  rightTitles: const AxisTitles(
                    sideTitles: SideTitles(showTitles: false),
                  ),
                  topTitles: const AxisTitles(
                    sideTitles: SideTitles(showTitles: false),
                  ),
                ),
                lineBarsData: [
                  // ── 매매가: kPrimary 실선 + 연한 fill ──────────────────────
                  LineChartBarData(
                    spots: data.saleSpots,
                    isCurved: true,
                    curveSmoothness: 0.35,
                    color: kPrimary,
                    barWidth: 2.5,
                    dotData: const FlDotData(show: false),
                    belowBarData: BarAreaData(
                      show: true,
                      color: kPrimary.withValues(alpha: 0.07),
                    ),
                  ),
                  // ── 전세가: kSecondary 점선 + 연한 fill ────────────────────
                  LineChartBarData(
                    spots: data.jeonseSpots,
                    isCurved: true,
                    curveSmoothness: 0.35,
                    color: kSecondary,
                    barWidth: 2.0,
                    dashArray: [6, 4],
                    dotData: const FlDotData(show: false),
                    belowBarData: BarAreaData(
                      show: true,
                      color: kSecondary.withValues(alpha: 0.05),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// 범례 점선/실선을 그리는 CustomPainter
class _DashLinePainter extends CustomPainter {
  const _DashLinePainter({required this.color, required this.dashed});
  final Color color;
  final bool dashed;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 2.5
      ..strokeCap = StrokeCap.round;
    final y = size.height / 2;
    if (!dashed) {
      canvas.drawLine(Offset(0, y), Offset(size.width, y), paint);
    } else {
      var x = 0.0;
      while (x < size.width) {
        canvas.drawLine(
          Offset(x, y),
          Offset((x + 4.0).clamp(0.0, size.width), y),
          paint,
        );
        x += 7.0;
      }
    }
  }

  @override
  bool shouldRepaint(_DashLinePainter old) => false;
}

class _BuildingInfoCard extends StatelessWidget {
  const _BuildingInfoCard();

  // ── 지표 셀 ──────────────────────────────────────────────────────────────
  Widget _statCell(IconData icon, Color iconColor, String label, String value) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: _kPageBg,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 아이콘 배지
            Container(
              width: 32,
              height: 32,
              decoration: BoxDecoration(
                color: iconColor.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(9),
              ),
              child: Icon(icon, size: 17, color: iconColor),
            ),
            const SizedBox(height: 9),
            // 라벨 (작고 은은한 회색)
            Text(
              label,
              style: const TextStyle(
                fontSize: 12,
                color: kTextMuted,
                fontWeight: FontWeight.w500,
              ),
            ),
            const SizedBox(height: 3),
            // 값 (크고 굵게)
            Text(
              value,
              style: const TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w800,
                color: kTextDark,
                letterSpacing: -0.3,
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ── 구조/난방 태그 ────────────────────────────────────────────────────────
  Widget _infoTag(String label) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: Colors.grey.shade100,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: kBorderColor, width: 0.8),
      ),
      child: Text(
        label,
        style: const TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w500,
          color: kTextMuted,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: kBorderColor),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ── 1행: 세대수 / 연차 ──────────────────────────────────────────────
          Row(
            children: [
              _statCell(Icons.apartment_rounded, kPrimary, '세대수', '1,542세대'),
              const SizedBox(width: 10),
              _statCell(
                Icons.calendar_today_rounded,
                kSecondary,
                '연차',
                '15년차 (2012)',
              ),
            ],
          ),
          const SizedBox(height: 10),
          // ── 2행: 주차 / 용적률·건폐율 ───────────────────────────────────────
          Row(
            children: [
              _statCell(
                Icons.directions_car_rounded,
                kPrimary,
                '주차',
                '세대당 1.15대',
              ),
              const SizedBox(width: 10),
              _statCell(
                Icons.stacked_bar_chart_rounded,
                kSecondary,
                '용적률/건폐율',
                '240% / 18%',
              ),
            ],
          ),
          // ── 구분선 ──────────────────────────────────────────────────────────
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Divider(height: 1, color: kBorderColor),
          ),
          // ── 구조/난방 태그 ───────────────────────────────────────────────────
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              _infoTag('개별난방'),
              _infoTag('계단식'),
              _infoTag('지역가스'),
              _infoTag('방음벽'),
            ],
          ),
        ],
      ),
    );
  }
}

class _SchoolLocationCard extends StatelessWidget {
  const _SchoolLocationCard();
  @override
  Widget build(BuildContext context) => Container(
    color: Colors.white,
    padding: const EdgeInsets.all(16),
    child: const Text('분당초등학교 / 정자역 도보 12분'),
  );
}

class _DongBreakdownCard extends StatelessWidget {
  const _DongBreakdownCard();
  @override
  Widget build(BuildContext context) => const ExpansionTile(
    title: Text('동별 세대수'),
    children: [ListTile(title: Text('101동 72세대'))],
  );
}

// _ImjangBottomSheet (기존과 동일하므로 빈 클래스 형태 또는 축약)
class _ImjangBottomSheet extends StatelessWidget {
  const _ImjangBottomSheet({required this.latLng});
  final NLatLng latLng;
  @override
  Widget build(BuildContext context) => Container(
    height: 300,
    color: Colors.white,
    child: const Center(child: Text('임장 기록 폼 (기존 유지)')),
  );
}

// ─────────────────────────────────────────────────────────────────────────────
// 말풍선 마커 위젯
// ─────────────────────────────────────────────────────────────────────────────

/// NOverlayImage.fromWidget()으로 렌더링되는 말풍선 마커.
///
/// [레이아웃]
///   ┌──────────────┐
///   │  8.5억  bold │  ← priceLabel (kPrimary, 14sp)
///   │    84㎡      │  ← areaLabel  (kTextMuted, 10sp) — 없으면 생략
///   └──────┬───────┘
///          ▼ 꼭지점 (말풍선 포인터)
///
/// 꼭지점 하단이 좌표에 정확히 맞도록 setAnchor(0.5, 1.0) 필수.
class _AptPriceBubble extends StatelessWidget {
  const _AptPriceBubble({required this.priceLabel, required this.areaLabel});

  final String priceLabel;
  final String areaLabel;

  static const _kPointerH = 7.0; // 말풍선 꼭지점 높이

  @override
  Widget build(BuildContext context) {
    final hasArea = areaLabel.isNotEmpty;
    final hasPrice = priceLabel.isNotEmpty;

    // Column 래퍼 불필요 — CustomPaint가 부모 constraint를 직접 받음
    return CustomPaint(
      painter: _BubblePainter(
        fillColor: Colors.white,
        strokeColor: kPrimary,
        pointerH: _kPointerH,
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(10, 6, 10, 6 + _kPointerH),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // 가격
            Text(
              hasPrice ? priceLabel : '시세 준비중',
              style: TextStyle(
                fontSize: hasPrice ? 12 : 11,
                fontWeight: FontWeight.w800,
                color: hasPrice ? kPrimary : kTextMuted,
                height: 1.1,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            // 면적 (있을 때만)
            if (hasArea) ...[
              const SizedBox(height: 1),
              Text(
                areaLabel,
                style: const TextStyle(
                  fontSize: 10,
                  fontWeight: FontWeight.w500,
                  color: kTextMuted,
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

/// 말풍선 모양 CustomPainter.
/// 둥근 사각형 본체 + 하단 중앙 삼각형 포인터를 하나의 Path로 그림.
class _BubblePainter extends CustomPainter {
  const _BubblePainter({
    required this.fillColor,
    required this.strokeColor,
    required this.pointerH,
  });

  final Color fillColor;
  final Color strokeColor;
  final double pointerH;

  static const _radius = 8.0;
  static const _pointerW = 12.0; // 포인터 밑변 너비
  static const _stroke = 1.5;

  @override
  void paint(Canvas canvas, Size size) {
    final bodyH = size.height - pointerH;
    final cx = size.width / 2;

    final path = Path()
      // 상단 좌측 모서리
      ..moveTo(_radius, 0)
      ..lineTo(size.width - _radius, 0)
      ..arcToPoint(
        Offset(size.width, _radius),
        radius: const Radius.circular(_radius),
      )
      // 우측 변
      ..lineTo(size.width, bodyH - _radius)
      ..arcToPoint(
        Offset(size.width - _radius, bodyH),
        radius: const Radius.circular(_radius),
      )
      // 포인터 우측
      ..lineTo(cx + _pointerW / 2, bodyH)
      // 포인터 꼭지점
      ..lineTo(cx, size.height)
      // 포인터 좌측
      ..lineTo(cx - _pointerW / 2, bodyH)
      // 좌측 변
      ..lineTo(_radius, bodyH)
      ..arcToPoint(
        Offset(0, bodyH - _radius),
        radius: const Radius.circular(_radius),
      )
      ..lineTo(0, _radius)
      ..arcToPoint(
        const Offset(_radius, 0),
        radius: const Radius.circular(_radius),
      )
      ..close();

    // 그림자
    canvas.drawShadow(path, Colors.black26, 3, false);

    // 채우기
    canvas.drawPath(
      path,
      Paint()
        ..color = fillColor
        ..style = PaintingStyle.fill,
    );

    // 테두리
    canvas.drawPath(
      path,
      Paint()
        ..color = strokeColor
        ..style = PaintingStyle.stroke
        ..strokeWidth = _stroke
        ..strokeJoin = StrokeJoin.round,
    );
  }

  @override
  bool shouldRepaint(_BubblePainter old) =>
      old.fillColor != fillColor ||
      old.strokeColor != strokeColor ||
      old.pointerH != pointerH;
}
