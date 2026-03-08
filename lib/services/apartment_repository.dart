import 'dart:convert';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:xml/xml.dart';
import 'dart:math';

// ─── API 키 & 엔드포인트 ────────────────────────────────────────────────────────
// 공공데이터포털: 국토교통부_공동주택 단지 목록제공 서비스
// https://www.data.go.kr/data/15044075/openapi.do
// ⚠️  serviceKey는 포털 발급 인증키(Encoding) 그대로 사용 — 이중 인코딩 방지를 위해 수동 URL 조합
const _kAptListBaseUrl =
    'https://apis.data.go.kr/1613000/AptListService3/getAptList';

// 카카오 로컬 API — 키워드 검색 (단지주소 → 위경도 변환)
const _kKakaoSearchUrl = 'https://dapi.kakao.com/v2/local/search/keyword.json';

// ─────────────────────────────────────────────────────────────────────────────
// 데이터 모델
// ─────────────────────────────────────────────────────────────────────────────

/// Firestore `apartments/{kaptCode}` 문서 스키마와 1:1 대응하는 단지 기본 정보 모델.
///
/// [필드 출처]
///   kaptCode · kaptName · kaptAddr — 국토교통부 공동주택 단지 목록 API
///   bjdCode                        — 호출 파라미터 (쿼리 인덱스 겸 파티션 키)
///   lat · lng                      — 카카오 로컬 API (공공 API 미제공 → 보강)
///   cachedAt                       — Firestore 저장 시각 (serverTimestamp)
class ApartmentInfo {
  const ApartmentInfo({
    required this.kaptCode,
    required this.kaptName,
    required this.bjdCode,
    required this.kaptAddr,
    required this.lat,
    required this.lng,
  });

  final String kaptCode; // 단지코드 (Firestore doc ID / PK)
  final String kaptName; // 단지명
  final String bjdCode; // 법정동코드 (where 쿼리 인덱스)
  final String kaptAddr; // 단지 주소 (카카오 geocoding 소스)
  final double lat; // 위도  (미취득 시 0.0)
  final double lng; // 경도  (미취득 시 0.0)

  /// 지도에 렌더링 가능한 유효 좌표 여부.
  bool get hasValidCoords => lat != 0.0 && lng != 0.0;

  /// Firestore DocumentSnapshot → ApartmentInfo.
  factory ApartmentInfo.fromFirestore(
    DocumentSnapshot<Map<String, dynamic>> doc,
  ) {
    final d = doc.data()!;
    return ApartmentInfo(
      kaptCode: doc.id,
      kaptName: d['kaptName'] as String? ?? '',
      bjdCode: d['bjdCode'] as String? ?? '',
      kaptAddr: d['kaptAddr'] as String? ?? '',
      lat: (d['lat'] as num?)?.toDouble() ?? 0.0,
      lng: (d['lng'] as num?)?.toDouble() ?? 0.0,
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
    'cachedAt': FieldValue.serverTimestamp(),
  };
}

// ─────────────────────────────────────────────────────────────────────────────
// ApartmentRepository — Read-Through Cache
// ─────────────────────────────────────────────────────────────────────────────

/// Firebase Read-Through Cache 패턴으로 아파트 단지 목록을 제공하는 Repository.
///
/// [Cache Hit]
///   Firestore `apartments` 컬렉션에 bjdCode 일치 문서 존재
///   → 추가 외부 API 호출 없이 파싱하여 즉시 반환 (평균 응답 < 150ms).
///
/// [Cache Miss]
///   1. 국토교통부 공동주택 단지 목록 API 호출 → XML 파싱
///   2. 카카오 로컬 API 병렬 호출 → 위경도 보강
///   3. Firestore WriteBatch 저장 (최대 400 ops/batch, 자동 페이지 분할)
///   4. 완성된 목록 반환
///
/// [사용 예시 — 지도 이동 이벤트 연결]
/// ```dart
/// // onCameraIdle 또는 마커 렌더링 진입점에서 호출
/// final apts = await ApartmentRepository.instance
///     .getApartmentsByBjdCode('4113510300'); // 분당구 수내1동
/// ```
class ApartmentRepository {
  ApartmentRepository._();
  static final ApartmentRepository instance = ApartmentRepository._();

  final _db = FirebaseFirestore.instance;

  CollectionReference<Map<String, dynamic>> get _col =>
      _db.collection('apartments');

  // ── Public Entry Point ────────────────────────────────────────────────────

  /// [bjdCode] 법정동코드에 해당하는 아파트 단지 목록을 반환.
  ///
  /// - Cache Hit  → Firestore 결과 즉시 반환
  /// - Cache Miss → 공공API + 카카오 좌표 보강 → Firestore 저장 후 반환
  /// - 공공API/좌표 취득 실패 시 예외를 던지지 않고 빈 리스트 반환
  ///   (지도 UX 보호: 일부 단지 좌표 0.0이면 hasValidCoords 필터 활용)
  Future<List<ApartmentInfo>> getApartmentsByBjdCode(String bjdCode) async {
    // ── Step 1. Firestore Cache Check ───────────────────────────────────────
    debugPrint('[AptRepo] ── Cache check ── bjdCode: $bjdCode');
    try {
      final snap = await _col.where('bjdCode', isEqualTo: bjdCode).get();

      if (snap.docs.isNotEmpty) {
        // TTL 검사: 첫 번째 문서의 cachedAt이 7일 이상 지났으면 Stale로 간주
        final cachedAt =
            snap.docs.first.data()['cachedAt'] as Timestamp?;
        final isStale = cachedAt == null ||
            DateTime.now().difference(cachedAt.toDate()).inDays >= 7;

        if (!isStale) {
          final items =
              snap.docs.map((d) => ApartmentInfo.fromFirestore(d)).toList();
          // 유효 좌표가 하나도 없으면 이전 Kakao 실패로 저장된 불량 캐시.
          // Cache Miss로 처리하여 재호출.
          if (items.any((a) => a.hasValidCoords)) {
            debugPrint('[AptRepo] ✅ Cache HIT — ${items.length}개 단지');
            return items;
          }
          debugPrint('[AptRepo] ⚠️ Cache 유효하나 좌표 없음 — 재호출');
        } else {
          debugPrint('[AptRepo] ⚠️ Cache STALE — TTL 초과, 재호출');
        }
      }
    } catch (e) {
      // Firestore 읽기 실패 → Cache Miss로 진행
      debugPrint('[AptRepo] Firestore 읽기 오류 (Cache Miss 처리): $e');
    }

    // ── Step 2. Cache MISS → 공공 API 호출 ─────────────────────────────────
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

    // ── Step 3. 카카오 로컬 API — 위경도 병렬 보강 (Rate Limit 방어 적용) ──
    debugPrint('[AptRepo] 좌표 보강 시작 — ${rawList.length}개 단지 분할 처리');

    final enriched = <ApartmentInfo>[];
    const kakaoChunk = 5; // 한 번에 5개씩 묶어서 (너무 많으면 에러남)
    const kakaoDelay = Duration(milliseconds: 500); // 0.5초 간격으로 요청 (안전장치)

    for (var i = 0; i < rawList.length; i += kakaoChunk) {
      // 1. 전체 리스트에서 5개씩 잘라내기
      final chunk = rawList.sublist(i, min(i + kakaoChunk, rawList.length));

      // 2. 잘라낸 5개만 Future.wait으로 병렬 요청
      final chunkResult = await Future.wait(chunk.map(_enrichWithKakaoCoords));
      enriched.addAll(chunkResult);

      // 3. 아직 요청할 데이터가 남았다면 0.5초 대기 (카카오 서버 숨돌릴 시간)
      if (i + kakaoChunk < rawList.length) {
        await Future.delayed(kakaoDelay);
      }
    }

    debugPrint(
      '[AptRepo] 좌표 보강 완료 — '
      '성공: ${enriched.where((a) => a.hasValidCoords).length}개 / '
      '실패: ${enriched.where((a) => !a.hasValidCoords).length}개',
    );

    // ── Step 4. Firestore WriteBatch 저장 ──────────────────────────────────
    try {
      await _batchSave(enriched);
      debugPrint('[AptRepo] Firestore 저장 완료 — ${enriched.length}개');
    } catch (e) {
      // 저장 실패해도 이번 호출 결과는 반환 (다음 호출 시 재시도)
      debugPrint('[AptRepo] Firestore 저장 실패 (결과는 반환): $e');
    }

    return enriched;
  }

  // ── Private: 공공 API 호출 ────────────────────────────────────────────────

  /// 국토교통부 공동주택 단지 목록 API 호출 및 XML 파싱.
  ///
  /// 페이지당 100개씩, `totalCount` 기반으로 전체 페이지를 순차 조회.
  /// (분당구 전체 단지 약 400개 → 4 페이지)
  Future<List<ApartmentInfo>> _fetchAptListFromPublicApi(String bjdCode) async {
    const pageSize = 100;
    final result = <ApartmentInfo>[];
    int pageNo = 1;
    int totalCount = 1; // 첫 응답 전 루프 진입을 위한 초기값

    while (result.length < totalCount) {
      final url =
          '$_kAptListBaseUrl'
          '?serviceKey=${dotenv.env['PUBLIC_DATA_KEY']}'
          '&bjdCode=$bjdCode'
          '&numOfRows=$pageSize'
          '&pageNo=$pageNo';

      debugPrint('[AptRepo] 공공API 요청 — page $pageNo');
      final res = await http
          .get(Uri.parse(url))
          .timeout(const Duration(seconds: 15));

      if (res.statusCode != 200) {
        // 500: 서비스키 미등록 or bjdCode 형식 오류 (10자리 필요)
        debugPrint(
          '[AptRepo] 공공API HTTP ${res.statusCode} — body: ${res.body}',
        );
        throw Exception('[AptRepo] 공공API HTTP ${res.statusCode}');
      }

      final bodyStr = utf8.decode(res.bodyBytes);
      final doc = XmlDocument.parse(bodyStr);

      // resultCode 검증 (공공데이터 표준: '00' / '000' = 정상)
      final code = doc
          .findAllElements('resultCode')
          .firstOrNull
          ?.innerText
          .trim();
      if (code != null && code != '00' && code != '000') {
        final msg =
            doc.findAllElements('resultMsg').firstOrNull?.innerText.trim() ??
            '';
        throw Exception('[AptRepo] 공공API 오류 ($code): $msg');
      }

      // 첫 페이지에서 totalCount 확정
      if (pageNo == 1) {
        final raw = doc
            .findAllElements('totalCount')
            .firstOrNull
            ?.innerText
            .trim();
        totalCount = int.tryParse(raw ?? '0') ?? 0;
        debugPrint('[AptRepo] totalCount = $totalCount');
        if (totalCount == 0) break;
      }

      final items = doc.findAllElements('item').toList();
      for (final el in items) {
        String t(String tag) =>
            el.findElements(tag).firstOrNull?.innerText.trim() ?? '';

        final kaptCode = t('kaptCode');
        if (kaptCode.isEmpty) continue; // 코드 없는 행 스킵

        result.add(
          ApartmentInfo(
            kaptCode: kaptCode,
            kaptName: t('kaptName'),
            bjdCode: bjdCode,
            // kaptAddr 우선, 없으면 단지명으로 폴백 (카카오 검색 쿼리 보장)
            kaptAddr: t('kaptAddr').isNotEmpty ? t('kaptAddr') : t('kaptName'),
            lat: 0.0, // 카카오 보강 전 임시
            lng: 0.0,
          ),
        );
      }

      // 더 이상 결과 없거나 마지막 페이지면 탈출
      if (items.isEmpty || result.length >= totalCount) break;
      pageNo++;
    }

    debugPrint('[AptRepo] 공공API 파싱 완료 — ${result.length}개 단지');
    return result;
  }

  // ── Private: 카카오 좌표 보강 ─────────────────────────────────────────────

  /// 카카오 키워드 검색으로 단지의 위경도를 보강.
  ///
  /// 검색 쿼리: "${kaptName} ${kaptAddr}" — 단지명+주소 조합으로 정확도 최대화.
  /// 실패(네트워크 오류·결과 없음) 시 원본 ApartmentInfo(lat/lng=0.0) 반환.
  Future<ApartmentInfo> _enrichWithKakaoCoords(ApartmentInfo apt) async {
    try {
      final query = Uri.encodeComponent('${apt.kaptName} ${apt.kaptAddr}');
      final uri = Uri.parse('$_kKakaoSearchUrl?query=$query&size=1');
      final res = await http
          .get(
            uri,
            headers: {
              'Authorization': 'KakaoAK ${dotenv.env['KAKAO_REST_API_KEY']}',
            },
          )
          .timeout(const Duration(seconds: 10));

      if (res.statusCode != 200) return apt;

      final body = jsonDecode(res.body) as Map<String, dynamic>;
      final docs = body['documents'] as List<dynamic>;
      if (docs.isEmpty) return apt;

      final first = docs.first as Map<String, dynamic>;
      final lat = double.tryParse(first['y'] as String? ?? '') ?? 0.0;
      final lng = double.tryParse(first['x'] as String? ?? '') ?? 0.0;

      return ApartmentInfo(
        kaptCode: apt.kaptCode,
        kaptName: apt.kaptName,
        bjdCode: apt.bjdCode,
        kaptAddr: apt.kaptAddr,
        lat: lat,
        lng: lng,
      );
    } catch (e) {
      debugPrint('[AptRepo] 카카오 좌표 보강 실패 (${apt.kaptName}): $e');
      return apt;
    }
  }

  // ── Private: Firestore WriteBatch 저장 ───────────────────────────────────

  /// WriteBatch로 아파트 목록을 Firestore에 일괄 저장.
  ///
  /// Firestore WriteBatch 한도: 500 ops/batch.
  /// 400개씩 청크 분할하여 안전 마진 유지.
  /// 동일 kaptCode 재방문 시 `set()`의 merge 없이 전체 덮어쓰기
  /// → 좌표 업데이트 포함한 데이터 최신화 보장.
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
