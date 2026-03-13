import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';

// ─────────────────────────────────────────────────────────────────────────────
// 내부 캐시 헬퍼
// ─────────────────────────────────────────────────────────────────────────────

class _CacheEntry<T> {
  _CacheEntry(this.value, this.at);
  final T value;
  final DateTime at;
}

/// TTL 기반 인메모리 캐시.
/// T = nullable 타입도 지원 (null 결과도 캐시하여 재조회 방지).
class _TimedCache<T> {
  _TimedCache(this.ttl);

  final Duration ttl;
  final Map<String, _CacheEntry<T>> _store = {};

  /// 캐시에 유효한 엔트리가 있으면 true.
  bool has(String key) {
    final e = _store[key];
    return e != null && DateTime.now().difference(e.at) < ttl;
  }

  /// 캐시 읽기. 없거나 만료되면 null 반환.
  T? read(String key) {
    if (!has(key)) return null;
    return _store[key]!.value;
  }

  /// 캐시 쓰기.
  void write(String key, T value) {
    _store[key] = _CacheEntry(value, DateTime.now());
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// 데이터 모델
// ─────────────────────────────────────────────────────────────────────────────

/// 지도 마커용 단지 정보 모델.
/// apartments_by_bjd/{bjdCode}.apartments[] 배열의 각 항목과 1:1 대응.
class ApartmentInfo {
  const ApartmentInfo({
    required this.kaptCode,
    required this.kaptName,
    required this.bjdCode,
    this.kaptAddr = '',
    required this.lat,
    required this.lng,
    this.kakaoName,
    this.recentPrice = '',
  });

  /// aptCode (법정동코드_지번, 예: "1129013500_1028")
  /// apartment_trades의 문서 ID와 동일.
  final String kaptCode;

  /// 국토부 아파트명 (aptName_molit)
  final String kaptName;

  /// 법정동코드 10자리 (apartments_by_bjd 문서 ID)
  final String bjdCode;

  /// 지번주소 (미제공 시 공백)
  final String kaptAddr;

  final double lat;
  final double lng;

  /// 카카오 지도 아파트명 (kakaoName)
  final String? kakaoName;

  /// 최근 거래가 문자열 (예: "9.5억"). Firestore에 적재된 값.
  final String recentPrice;

  bool get hasValidCoords => lat != 0.0 && lng != 0.0;

  /// apartments_by_bjd 배열 항목 → ApartmentInfo
  factory ApartmentInfo.fromMarkerMap(
    Map<String, dynamic> m, {
    required String bjdCode,
  }) {
    return ApartmentInfo(
      kaptCode: m['aptCode']?.toString() ?? '',
      kaptName: m['aptName_molit']?.toString() ?? '',
      bjdCode: bjdCode,
      kaptAddr: m['address']?.toString() ?? '',
      lat: (m['lat'] as num?)?.toDouble() ?? 0.0,
      lng: (m['lng'] as num?)?.toDouble() ?? 0.0,
      kakaoName: m['kakaoName'] as String?,
      recentPrice: m['recentPrice']?.toString() ?? '',
    );
  }
}

/// 바텀시트 상세 정보 모델.
/// apartment_details/{kaptCode} 문서와 대응.
class ApartmentDetail {
  const ApartmentDetail({
    this.complexName = '',
    this.kakaoName,
    this.buildYear = 0,
    this.totalHouseholds = 0,
    this.parkingPerHousehold = 0.0,
    this.heatingMethod = '',
    this.facilities = '',
    this.busStopDistance = '',
    this.subwayStation = '',
    this.highestFloor = 0,
    this.lowestFloor = 0,
    this.dongCount = 0,
    this.address = '',
    this.roadAddress = '',
    this.builder = '',
  });

  final String complexName;
  final String? kakaoName;
  final int buildYear;
  final int totalHouseholds;
  final double parkingPerHousehold; // 세대당 주차수
  final String heatingMethod;
  final String facilities;
  final String busStopDistance;
  final String subwayStation;
  final int highestFloor;
  final int lowestFloor;
  final int dongCount;
  final String address;    // 지번주소
  final String roadAddress; // 도로명주소
  final String builder;

  factory ApartmentDetail.fromFirestore(Map<String, dynamic> d) {
    return ApartmentDetail(
      complexName: d['complexName']?.toString() ?? '',
      kakaoName: d['kakaoName'] as String?,
      buildYear: (d['buildYear'] as num?)?.toInt() ?? 0,
      totalHouseholds: (d['totalHouseholds'] as num?)?.toInt() ?? 0,
      parkingPerHousehold:
          (d['parkingPerHousehold'] as num?)?.toDouble() ?? 0.0,
      heatingMethod: d['heatingMethod']?.toString() ?? '',
      facilities: d['facilities']?.toString() ?? '',
      busStopDistance: d['busStopDistance']?.toString() ?? '',
      subwayStation: d['subwayStation']?.toString() ?? '',
      highestFloor: (d['highestFloor'] as num?)?.toInt() ?? 0,
      lowestFloor: (d['lowestFloor'] as num?)?.toInt() ?? 0,
      dongCount: (d['dongCount'] as num?)?.toInt() ?? 0,
      address: d['address']?.toString() ?? '',
      roadAddress: d['roadAddress']?.toString() ?? '',
      builder: d['builder']?.toString() ?? '',
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// ApartmentRepository — Firestore 직접 조회 + 인메모리 캐싱
// ─────────────────────────────────────────────────────────────────────────────

/// Firestore에 미리 적재된 데이터를 조회하는 Repository.
///
/// [Firestore Read 최소화 전략]
///   1. 인메모리 캐시 (_TimedCache) — TTL 내 동일 키 재조회 시 Firestore 미호출
///   2. In-flight 중복 방지 — 동일 키에 대한 동시 요청을 하나의 Future로 합산
///   3. null 결과도 캐시 — 데이터 없는 단지 반복 조회 방지
class ApartmentRepository {
  ApartmentRepository._();
  static final ApartmentRepository instance = ApartmentRepository._();

  final _db = FirebaseFirestore.instance;

  // ── 마커 캐시 ─────────────────────────────────────────────────────────────
  // TTL 1시간: 사용자가 같은 동네를 스크롤 아웃 후 재진입해도 Firestore 미조회.
  // 배치 갱신 주기가 1시간보다 짧다면 TTL을 줄이세요.
  final _markerCache = _TimedCache<List<ApartmentInfo>>(
    const Duration(hours: 1),
  );

  // 마커 조회 in-flight: 동일 bjdCode 동시 요청 시 Firestore 1회만 호출.
  final Map<String, Future<List<ApartmentInfo>>> _markerInflight = {};

  // ── 상세 캐시 ─────────────────────────────────────────────────────────────
  // TTL 24시간: 단지 스펙(세대수·층수 등)은 하루 단위로도 충분.
  // null도 캐시하여 데이터 없는 단지 반복 쿼리 방지.
  final _detailCache = _TimedCache<ApartmentDetail?>(
    const Duration(hours: 24),
  );

  // 상세 조회 in-flight: 같은 단지 바텀시트를 빠르게 닫았다 다시 열 때 보호.
  final Map<String, Future<ApartmentDetail?>> _detailInflight = {};

  // ── 구별 평균가 캐시 ──────────────────────────────────────────────────────
  // TTL 6시간: 홈 화면 시세 카드용. 배치 갱신이 하루 1~2회이므로 충분.
  final _districtCache = _TimedCache<({int avgPrice, int count})>(
    const Duration(hours: 6),
  );
  final Map<String, Future<({int avgPrice, int count})>> _districtInflight = {};

  // ── 마커 목록 조회: apartments_by_bjd/{bjdCode} ──────────────────────────

  /// 법정동 코드에 해당하는 아파트 마커 목록 반환.
  Future<List<ApartmentInfo>> getApartmentsByBjdCode(String bjdCode) async {
    // 1. 메모리 캐시 확인
    final cached = _markerCache.read(bjdCode);
    if (cached != null) {
      debugPrint('[AptRepo] 캐시 HIT — bjdCode: $bjdCode (${cached.length}개)');
      return cached;
    }

    // 2. In-flight 합산: 동일 bjdCode 요청이 이미 진행 중이면 그 Future 반환
    return _markerInflight.putIfAbsent(bjdCode, () async {
      debugPrint('[AptRepo] Firestore 마커 조회 — bjdCode: $bjdCode');
      try {
        final doc = await _db
            .collection('apartments_by_bjd')
            .doc(bjdCode)
            .get();

        List<ApartmentInfo> result = [];

        if (doc.exists) {
          final data = doc.data()!;
          final rawList = data['apartments'];
          if (rawList is List) {
            result = rawList
                .whereType<Map<String, dynamic>>()
                .map((m) => ApartmentInfo.fromMarkerMap(m, bjdCode: bjdCode))
                .where((a) => a.hasValidCoords && a.kaptCode.isNotEmpty)
                .toList();
          }
        }

        debugPrint('[AptRepo] ✅ ${result.length}개 단지 — bjdCode: $bjdCode');
        _markerCache.write(bjdCode, result);
        return result;
      } catch (e) {
        debugPrint('[AptRepo] 마커 조회 오류: $e');
        return [];
      } finally {
        // 완료 후 in-flight에서 제거
        _markerInflight.remove(bjdCode);
      }
    });
  }

  // ── 구별 평균 매매가 조회: apartments_by_bjd (범위 쿼리) ─────────────────────

  /// lawdCd5(5자리 법정동코드)에 해당하는 구의 아파트 평균 최근 거래가 반환.
  ///
  /// 반환값: (avgPrice: 만원 단위 평균, count: 유효 단지 수)
  /// count == 0 이면 데이터 없음.
  Future<({int avgPrice, int count})> getDistrictAvgPrice(
    String lawdCd5,
  ) async {
    if (lawdCd5.isEmpty) return (avgPrice: 0, count: 0);

    // 1. 메모리 캐시 확인
    if (_districtCache.has(lawdCd5)) {
      final cached = _districtCache.read(lawdCd5)!;
      debugPrint('[AptRepo] 구별 평균가 캐시 HIT — $lawdCd5 (${cached.count}건)');
      return cached;
    }

    // 2. In-flight 합산
    return _districtInflight.putIfAbsent(lawdCd5, () async {
      debugPrint('[AptRepo] Firestore 구별 평균가 조회 — lawdCd5: $lawdCd5');
      try {
        // 10자리 bjdCode 범위: lawdCd5+'00000' ~ (lawdCd5+1)+'00000'
        final lower = '${lawdCd5}00000';
        final upper =
            '${(int.parse(lawdCd5) + 1).toString().padLeft(5, '0')}00000';

        final snap = await _db
            .collection('apartments_by_bjd')
            .where(FieldPath.documentId, isGreaterThanOrEqualTo: lower)
            .where(FieldPath.documentId, isLessThan: upper)
            .get();

        int total = 0;
        int count = 0;
        for (final doc in snap.docs) {
          final rawList = doc.data()['apartments'];
          if (rawList is! List) continue;
          for (final item in rawList) {
            if (item is! Map) continue;
            final priceStr = item['recentPrice']?.toString() ?? '';
            final parsed = _parseRecentPrice(priceStr);
            if (parsed > 0) {
              total += parsed;
              count++;
            }
          }
        }

        final result = (avgPrice: count > 0 ? total ~/ count : 0, count: count);
        debugPrint('[AptRepo] ✅ 구별 평균가 — $lawdCd5: ${result.avgPrice}만원 (${result.count}건)');
        _districtCache.write(lawdCd5, result);
        return result;
      } catch (e) {
        debugPrint('[AptRepo] 구별 평균가 조회 오류: $e');
        return (avgPrice: 0, count: 0);
      } finally {
        _districtInflight.remove(lawdCd5);
      }
    });
  }

  /// "9.5억" / "13억" / "9,000만" 등의 문자열 → 만원 정수.
  static int _parseRecentPrice(String s) {
    if (s.isEmpty) return 0;
    if (s.contains('억')) {
      final eokStr = s.split('억').first.trim();
      final eok = double.tryParse(eokStr) ?? 0.0;
      return (eok * 10000).round();
    }
    if (s.contains('만')) {
      final manStr = s.replaceAll('만', '').replaceAll(',', '').trim();
      return int.tryParse(manStr) ?? 0;
    }
    return 0;
  }

  // ── 상세 정보 조회: apartment_details ────────────────────────────────────

  /// aptCode에 해당하는 단지 상세정보 반환.
  ///
  /// 조회 전략:
  ///   1차: apartment_details.where('aptCode', isEqualTo: aptCode)
  ///   2차 fallback: .where('lat').where('lng') 좌표 매칭
  Future<ApartmentDetail?> getApartmentDetail(
    String aptCode, {
    double? lat,
    double? lng,
  }) async {
    if (aptCode.isEmpty) return null;

    // 1. 메모리 캐시 확인 (null도 캐시됨 → has() 로 판별)
    if (_detailCache.has(aptCode)) {
      debugPrint('[AptRepo] 상세 캐시 HIT — $aptCode');
      return _detailCache.read(aptCode);
    }

    // 2. In-flight 합산
    return _detailInflight.putIfAbsent(aptCode, () async {
      debugPrint('[AptRepo] Firestore 상세정보 조회 — aptCode: $aptCode');
      try {
        ApartmentDetail? result;

        // 1차: aptCode 필드 쿼리
        final snap = await _db
            .collection('apartment_details')
            .where('aptCode', isEqualTo: aptCode)
            .limit(1)
            .get();

        if (snap.docs.isNotEmpty) {
          debugPrint('[AptRepo] 상세정보 ✅ aptCode 매칭');
          result = ApartmentDetail.fromFirestore(snap.docs.first.data());
        } else if (lat != null && lng != null && lat != 0.0 && lng != 0.0) {
          // 2차 fallback: 좌표 쿼리
          final snapCoord = await _db
              .collection('apartment_details')
              .where('lat', isEqualTo: lat)
              .where('lng', isEqualTo: lng)
              .limit(1)
              .get();

          if (snapCoord.docs.isNotEmpty) {
            debugPrint('[AptRepo] 상세정보 ✅ 좌표 매칭');
            result = ApartmentDetail.fromFirestore(snapCoord.docs.first.data());
          }
        }

        if (result == null) {
          debugPrint('[AptRepo] 상세정보 없음 — $aptCode (null 캐시 저장)');
        }

        // null도 캐시 저장 → 동일 aptCode 반복 쿼리 방지
        _detailCache.write(aptCode, result);
        return result;
      } catch (e) {
        debugPrint('[AptRepo] 상세정보 조회 오류: $e');
        // 오류 시 캐시하지 않음 → 다음 탭 시 재시도 가능
        return null;
      } finally {
        _detailInflight.remove(aptCode);
      }
    });
  }
}
