import 'dart:convert';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'dart:math';

// ─── API 키 & 엔드포인트 ────────────────────────────────────────────────────────
// 공공데이터포털: 국토교통부_공동주택 단지 목록제공 서비스
// https://www.data.go.kr/data/15044075/openapi.do
const _kAptListBaseUrl =
    'https://apis.data.go.kr/1613000/AptListService3/getLegaldongAptList3';

// 국토교통부_공동주택 기본정보 V4 (세대수, 층수, 난방, 건설사 등)
const _kAptBassInfoUrl =
    'https://apis.data.go.kr/1613000/AptBasisInfoServiceV4/getAphusBassInfoV4';

// 국토교통부_공동주택 상세정보 V4 (주차대수 등)
const _kAptDtlInfoUrl =
    'https://apis.data.go.kr/1613000/AptBasisInfoServiceV4/getAphusDtlInfoV4';

// 카카오 로컬 API — 키워드 검색 (단지주소 → 위경도 변환)
const _kKakaoSearchUrl = 'https://dapi.kakao.com/v2/local/search/keyword.json';

// 스키마 버전: 필드 추가 시 올려서 구 캐시를 자동 무효화
const _kSchemaVersion = 5;

// ─────────────────────────────────────────────────────────────────────────────
// 데이터 모델
// ─────────────────────────────────────────────────────────────────────────────

/// Firestore `apartments/{kaptCode}` 문서 스키마와 1:1 대응하는 단지 정보 모델.
class ApartmentInfo {
  const ApartmentInfo({
    required this.kaptCode,
    required this.kaptName,
    required this.bjdCode,
    required this.kaptAddr,
    required this.lat,
    required this.lng,
    this.roadAddr = '',
    this.totalHouseholds = 0,
    this.dongCount = 0,
    this.minFloor = 0,
    this.maxFloor = 0,
    this.approvalDate = '',
    this.totalParkingCount = 0,
    this.floorAreaRatio = 0,
    this.buildingCoverageRatio = 0,
    this.builder = '',
    this.heatingType = '',
    this.managementOffice = '',
  });

  final String kaptCode;          // 단지코드 (Firestore doc ID / PK)
  final String kaptName;          // 단지명
  final String bjdCode;           // 법정동코드 (where 쿼리 인덱스)
  final String kaptAddr;          // 지번 주소
  final double lat;               // 위도  (미취득 시 0.0)
  final double lng;               // 경도  (미취득 시 0.0)
  final String roadAddr;          // 도로명 주소
  final int totalHouseholds;      // 세대수
  final int dongCount;            // 동수
  final int minFloor;             // 최저층
  final int maxFloor;             // 최고층
  final String approvalDate;      // 사용승인일 (YYYY.MM.DD)
  final int totalParkingCount;    // 총 주차대수
  final int floorAreaRatio;       // 용적률 (%)
  final int buildingCoverageRatio;// 건폐율 (%)
  final String builder;           // 건설사
  final String heatingType;       // 난방방식
  final String managementOffice;  // 관리사무소

  /// 지도에 렌더링 가능한 유효 좌표 여부.
  bool get hasValidCoords => lat != 0.0 && lng != 0.0;

  /// Firestore DocumentSnapshot → ApartmentInfo.
  factory ApartmentInfo.fromFirestore(
    DocumentSnapshot<Map<String, dynamic>> doc,
  ) {
    final d = doc.data()!;
    // approvalDate: YYYYMMDD → YYYY.MM.DD 변환
    final rawDate = d['approvalDate'] as String? ?? '';
    final fmtDate = _formatApprovalDate(rawDate);

    return ApartmentInfo(
      kaptCode: doc.id,
      kaptName: d['kaptName'] as String? ?? '',
      bjdCode: d['bjdCode'] as String? ?? '',
      kaptAddr: d['kaptAddr'] as String? ?? '',
      lat: (d['lat'] as num?)?.toDouble() ?? 0.0,
      lng: (d['lng'] as num?)?.toDouble() ?? 0.0,
      roadAddr: d['roadAddr'] as String? ?? '',
      totalHouseholds: (d['totalHouseholds'] as num?)?.toInt() ?? 0,
      dongCount: (d['dongCount'] as num?)?.toInt() ?? 0,
      minFloor: (d['minFloor'] as num?)?.toInt() ?? 0,
      maxFloor: (d['maxFloor'] as num?)?.toInt() ?? 0,
      approvalDate: fmtDate,
      totalParkingCount: (d['totalParkingCount'] as num?)?.toInt() ?? 0,
      floorAreaRatio: (d['floorAreaRatio'] as num?)?.toInt() ?? 0,
      buildingCoverageRatio: (d['buildingCoverageRatio'] as num?)?.toInt() ?? 0,
      builder: d['builder'] as String? ?? '',
      heatingType: d['heatingType'] as String? ?? '',
      managementOffice: d['managementOffice'] as String? ?? '',
    );
  }

  /// Firestore 저장용 Map.
  Map<String, dynamic> toFirestore() => {
    'kaptCode': kaptCode,
    'kaptName': kaptName,
    'bjdCode': bjdCode,
    'kaptAddr': kaptAddr,
    'lat': lat,
    'lng': lng,
    'roadAddr': roadAddr,
    'totalHouseholds': totalHouseholds,
    'dongCount': dongCount,
    'minFloor': minFloor,
    'maxFloor': maxFloor,
    'approvalDate': approvalDate,
    'totalParkingCount': totalParkingCount,
    'floorAreaRatio': floorAreaRatio,
    'buildingCoverageRatio': buildingCoverageRatio,
    'builder': builder,
    'heatingType': heatingType,
    'managementOffice': managementOffice,
    'schemaVersion': _kSchemaVersion,
    'cachedAt': FieldValue.serverTimestamp(),
  };

  /// 복사 생성자 (일부 필드만 업데이트).
  ApartmentInfo copyWith({
    double? lat,
    double? lng,
    String? roadAddr,
    int? totalHouseholds,
    int? dongCount,
    int? minFloor,
    int? maxFloor,
    String? approvalDate,
    int? totalParkingCount,
    int? floorAreaRatio,
    int? buildingCoverageRatio,
    String? builder,
    String? heatingType,
    String? managementOffice,
  }) =>
      ApartmentInfo(
        kaptCode: kaptCode,
        kaptName: kaptName,
        bjdCode: bjdCode,
        kaptAddr: kaptAddr,
        lat: lat ?? this.lat,
        lng: lng ?? this.lng,
        roadAddr: roadAddr ?? this.roadAddr,
        totalHouseholds: totalHouseholds ?? this.totalHouseholds,
        dongCount: dongCount ?? this.dongCount,
        minFloor: minFloor ?? this.minFloor,
        maxFloor: maxFloor ?? this.maxFloor,
        approvalDate: approvalDate ?? this.approvalDate,
        totalParkingCount: totalParkingCount ?? this.totalParkingCount,
        floorAreaRatio: floorAreaRatio ?? this.floorAreaRatio,
        buildingCoverageRatio:
            buildingCoverageRatio ?? this.buildingCoverageRatio,
        builder: builder ?? this.builder,
        heatingType: heatingType ?? this.heatingType,
        managementOffice: managementOffice ?? this.managementOffice,
      );

  /// "20040630" → "2004년 06월 30일"
  static String _formatApprovalDate(String raw) {
    if (raw.length == 8) {
      return '${raw.substring(0, 4)}년 ${raw.substring(4, 6)}월 ${raw.substring(6, 8)}일';
    }
    return raw;
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// ApartmentRepository — Read-Through Cache
// ─────────────────────────────────────────────────────────────────────────────

/// Firebase Read-Through Cache 패턴으로 아파트 단지 목록을 제공하는 Repository.
class ApartmentRepository {
  ApartmentRepository._();
  static final ApartmentRepository instance = ApartmentRepository._();

  final _db = FirebaseFirestore.instance;

  CollectionReference<Map<String, dynamic>> get _col =>
      _db.collection('apartments');

  // ── Public Entry Point ────────────────────────────────────────────────────

  Future<List<ApartmentInfo>> getApartmentsByBjdCode(String bjdCode) async {
    debugPrint('[AptRepo] ── Cache check ── bjdCode: $bjdCode');
    try {
      final snap = await _col.where('bjdCode', isEqualTo: bjdCode).get();

      if (snap.docs.isNotEmpty) {
        final firstData = snap.docs.first.data();
        final cachedAt = firstData['cachedAt'] as Timestamp?;
        final schemaVersion = (firstData['schemaVersion'] as num?)?.toInt() ?? 1;
        final isStale = cachedAt == null ||
            DateTime.now().difference(cachedAt.toDate()).inDays >= 7;
        final isOldSchema = schemaVersion < _kSchemaVersion;

        if (!isStale && !isOldSchema) {
          final items =
              snap.docs.map((d) => ApartmentInfo.fromFirestore(d)).toList();
          if (items.any((a) => a.hasValidCoords)) {
            debugPrint('[AptRepo] ✅ Cache HIT — ${items.length}개 단지');
            return items;
          }
          debugPrint('[AptRepo] ⚠️ Cache 유효하나 좌표 없음 — 재호출');
        } else if (isOldSchema) {
          debugPrint('[AptRepo] ⚠️ 구 스키마(v$schemaVersion) — 재호출');
        } else {
          debugPrint('[AptRepo] ⚠️ Cache STALE — TTL 초과, 재호출');
        }
      }
    } catch (e) {
      debugPrint('[AptRepo] Firestore 읽기 오류 (Cache Miss 처리): $e');
    }

    debugPrint('[AptRepo] ❌ Cache MISS — 공공 API 호출 시작');
    final List<ApartmentInfo> rawList;
    try {
      rawList = await _fetchAptListFromPublicApi(bjdCode);
    } catch (e) {
      debugPrint('[AptRepo] 공공 API 호출 실패: $e');
      return [];
    }

    if (rawList.isEmpty) {
      debugPrint('[AptRepo] 공공 API 결과 없음 — bjdCode: $bjdCode');
      return [];
    }

    // 카카오 좌표 보강 + 단지 상세정보 병렬 호출
    debugPrint('[AptRepo] 좌표+상세정보 보강 시작 — ${rawList.length}개 단지');

    final enriched = <ApartmentInfo>[];
    const chunkSize = 5;
    const chunkDelay = Duration(milliseconds: 500);

    for (var i = 0; i < rawList.length; i += chunkSize) {
      final chunk = rawList.sublist(i, min(i + chunkSize, rawList.length));
      final chunkResult = await Future.wait(
        chunk.map((apt) async {
          // 좌표 + 상세정보 동시 요청
          final results = await Future.wait([
            _enrichWithKakaoCoords(apt),
            _fetchAptDetail(apt.kaptCode),
          ]);
          final withCoords = results[0] as ApartmentInfo;
          final detail = results[1] as Map<String, dynamic>;
          return withCoords.copyWith(
            roadAddr: detail['roadAddr'] as String?,
            totalHouseholds: detail['totalHouseholds'] as int?,
            dongCount: detail['dongCount'] as int?,
            minFloor: detail['minFloor'] as int?,
            maxFloor: detail['maxFloor'] as int?,
            approvalDate: detail['approvalDate'] as String?,
            totalParkingCount: detail['totalParkingCount'] as int?,
            floorAreaRatio: detail['floorAreaRatio'] as int?,
            buildingCoverageRatio: detail['buildingCoverageRatio'] as int?,
            builder: detail['builder'] as String?,
            heatingType: detail['heatingType'] as String?,
            managementOffice: detail['managementOffice'] as String?,
          );
        }),
      );
      enriched.addAll(chunkResult);
      if (i + chunkSize < rawList.length) {
        await Future.delayed(chunkDelay);
      }
    }

    debugPrint(
      '[AptRepo] 보강 완료 — '
      '좌표: ${enriched.where((a) => a.hasValidCoords).length}개 / '
      '세대수 있음: ${enriched.where((a) => a.totalHouseholds > 0).length}개',
    );

    try {
      await _batchSave(enriched);
      debugPrint('[AptRepo] Firestore 저장 완료 — ${enriched.length}개');
    } catch (e) {
      debugPrint('[AptRepo] Firestore 저장 실패 (결과는 반환): $e');
    }

    return enriched;
  }

  // ── Private: 공공 API 단지 목록 ───────────────────────────────────────────

  Future<List<ApartmentInfo>> _fetchAptListFromPublicApi(String bjdCode) async {
    final serviceKey = dotenv.env['PUBLIC_DATA_KEY'];
    if (serviceKey == null || serviceKey.isEmpty) {
      throw Exception('[AptRepo] PUBLIC_DATA_KEY가 .env에 설정되지 않았습니다.');
    }

    const pageSize = 100;
    final result = <ApartmentInfo>[];
    int pageNo = 1;
    int totalCount = 1;

    while (result.length < totalCount) {
      final url =
          '$_kAptListBaseUrl'
          '?serviceKey=$serviceKey'
          '&bjdCode=$bjdCode'
          '&numOfRows=$pageSize'
          '&pageNo=$pageNo';

      debugPrint('[AptRepo] 공공API 요청 — page $pageNo');
      final res = await http
          .get(Uri.parse(url))
          .timeout(const Duration(seconds: 15));

      if (res.statusCode != 200) {
        throw Exception('[AptRepo] 공공API HTTP ${res.statusCode}');
      }

      final bodyStr = utf8.decode(res.bodyBytes);
      final Map<String, dynamic> json;
      try {
        json = jsonDecode(bodyStr) as Map<String, dynamic>;
      } catch (e) {
        throw Exception('[AptRepo] JSON 파싱 실패: $e');
      }

      final response = json['response'] as Map<String, dynamic>?;
      final header = response?['header'] as Map<String, dynamic>?;
      final body = response?['body'] as Map<String, dynamic>?;

      final code = header?['resultCode']?.toString();
      if (code != null && code != '00' && code != '000') {
        final msg = header?['resultMsg']?.toString() ?? '';
        throw Exception('[AptRepo] 공공API 오류 ($code): $msg');
      }

      if (pageNo == 1) {
        totalCount = (body?['totalCount'] as num?)?.toInt() ?? 0;
        debugPrint('[AptRepo] totalCount = $totalCount');
        if (totalCount == 0) break;
      }

      final rawItems = body?['items'];
      final items = (rawItems is List) ? rawItems : <dynamic>[];

      for (final el in items) {
        if (el is! Map<String, dynamic>) continue;
        final kaptCode = el['kaptCode']?.toString() ?? '';
        if (kaptCode.isEmpty) continue;

        final as1 = el['as1']?.toString() ?? '';
        final as2 = el['as2']?.toString() ?? '';
        final as3 = el['as3']?.toString() ?? '';
        final kaptName = el['kaptName']?.toString() ?? '';
        final addr = [as1, as2, as3].where((s) => s.isNotEmpty).join(' ');

        result.add(
          ApartmentInfo(
            kaptCode: kaptCode,
            kaptName: kaptName,
            bjdCode: bjdCode,
            kaptAddr: addr.isNotEmpty ? addr : kaptName,
            lat: 0.0,
            lng: 0.0,
          ),
        );
      }

      if (items.isEmpty || result.length >= totalCount) break;
      pageNo++;
    }

    debugPrint('[AptRepo] 공공API 파싱 완료 — ${result.length}개 단지');
    return result;
  }

  // ── Private: 단지 상세정보 API (V4) ─────────────────────────────────────

  /// `AptBasisInfoServiceV4` (기본정보 + 상세정보) 병렬 호출 → 단지 상세 반환.
  /// 실패 시 빈 Map 반환.
  Future<Map<String, dynamic>> _fetchAptDetail(String kaptCode) async {
    try {
      final serviceKey = dotenv.env['PUBLIC_DATA_KEY'];
      if (serviceKey == null || serviceKey.isEmpty) return {};

      final bassUrl =
          '$_kAptBassInfoUrl?serviceKey=$serviceKey&kaptCode=$kaptCode&numOfRows=1&pageNo=1';
      final dtlUrl =
          '$_kAptDtlInfoUrl?serviceKey=$serviceKey&kaptCode=$kaptCode&numOfRows=1&pageNo=1';

      // 기본정보 + 상세정보 병렬 요청
      final responses = await Future.wait([
        http.get(Uri.parse(bassUrl)).timeout(const Duration(seconds: 10)),
        http.get(Uri.parse(dtlUrl)).timeout(const Duration(seconds: 10)),
      ]);

      Map<String, dynamic> parseItem(http.Response res) {
        if (res.statusCode != 200) return {};
        try {
          final j = jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
          final item = j['response']?['body']?['item'];
          return item is Map<String, dynamic> ? item : {};
        } catch (_) {
          return {};
        }
      }

      final bass = parseItem(responses[0]);
      final dtl  = parseItem(responses[1]);

      // JSON 필드를 타입 안전하게 파싱 (API가 숫자를 String으로 반환하는 경우 대응)
      int numOf(Map<String, dynamic> m, String key) {
        final v = m[key];
        if (v == null) return 0;
        if (v is num) return v.toInt();
        return int.tryParse(v.toString()) ?? 0;
      }

      // 주차대수: 지상 + 지하 합산
      final totalParking = numOf(dtl, 'kaptdPcnt') + numOf(dtl, 'kaptdPcntu');

      final result = <String, dynamic>{
        'roadAddr':          bass['doroJuso']?.toString() ?? '',
        'totalHouseholds':   numOf(bass, 'kaptdaCnt'),
        'dongCount':         numOf(bass, 'kaptDongCnt'),
        'minFloor':          numOf(bass, 'kaptBaseFloor'),
        'maxFloor':          numOf(bass, 'kaptTopFloor'),
        'approvalDate':      bass['kaptUsedate']?.toString() ?? '', // YYYYMMDD
        'totalParkingCount': totalParking,
        'floorAreaRatio':    0, // V4 API 미제공
        'buildingCoverageRatio': 0, // V4 API 미제공
        'builder':           bass['kaptBcompany']?.toString() ?? '',
        'heatingType':       bass['codeHeatNm']?.toString() ?? '',
        'managementOffice':  bass['kaptTel']?.toString() ?? '',
      };

      if ((result['totalHouseholds'] as int) > 0) {
        debugPrint(
          '[AptRepo] 상세정보 ✓ $kaptCode: '
          '${result['totalHouseholds']}세대, '
          '${result['minFloor']}~${result['maxFloor']}층, '
          '주차 $totalParking대',
        );
      }
      return result;
    } catch (e) {
      debugPrint('[AptRepo] 상세정보 호출 실패 ($kaptCode): $e');
      return {};
    }
  }

  // ── Private: 카카오 좌표 보강 ─────────────────────────────────────────────

  Future<ApartmentInfo> _enrichWithKakaoCoords(ApartmentInfo apt) async {
    try {
      final kakaoKey = dotenv.env['KAKAO_REST_API_KEY'];
      if (kakaoKey == null || kakaoKey.isEmpty) return apt;

      final query = Uri.encodeComponent('${apt.kaptName} ${apt.kaptAddr}');
      final uri = Uri.parse('$_kKakaoSearchUrl?query=$query&size=1');
      final res = await http
          .get(uri, headers: {'Authorization': 'KakaoAK $kakaoKey'})
          .timeout(const Duration(seconds: 10));

      if (res.statusCode != 200) return apt;

      final body = jsonDecode(res.body) as Map<String, dynamic>;
      final docs = body['documents'] as List<dynamic>;
      if (docs.isEmpty) return apt;

      final first = docs.first as Map<String, dynamic>;
      final lat = double.tryParse(first['y'] as String? ?? '') ?? 0.0;
      final lng = double.tryParse(first['x'] as String? ?? '') ?? 0.0;

      return apt.copyWith(lat: lat, lng: lng);
    } catch (e) {
      debugPrint('[AptRepo] 카카오 좌표 보강 실패 (${apt.kaptName}): $e');
      return apt;
    }
  }

  // ── Private: Firestore WriteBatch 저장 ───────────────────────────────────

  Future<void> _batchSave(List<ApartmentInfo> apts) async {
    if (apts.isEmpty) return;

    const chunkSize = 400;
    for (var i = 0; i < apts.length; i += chunkSize) {
      final end = (i + chunkSize).clamp(0, apts.length);
      final chunk = apts.sublist(i, end);

      final batch = _db.batch();
      for (final apt in chunk) {
        batch.set(_col.doc(apt.kaptCode), apt.toFirestore());
      }
      await batch.commit();
      debugPrint(
        '[AptRepo] Batch ${i ~/ chunkSize + 1} 커밋 완료 — ${chunk.length}개',
      );
    }
  }
}
