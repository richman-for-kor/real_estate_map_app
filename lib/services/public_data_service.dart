import 'dart:convert';

import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:xml/xml.dart';

// ─── 공공데이터포털 인증키 ──────────────────────────────────────────────────────
// 발급: https://www.data.go.kr → 국토교통부_아파트매매 실거래 상세 자료 → 활용신청
// ⚠️  serviceKey는 포털에서 발급한 인증키(Encoding) 값 그대로 사용합니다.
//     Uri.replace(queryParameters)로 전달하면 이중 인코딩 발생 → 수동 URL 조합 필수.

// ─── API 엔드포인트 ────────────────────────────────────────────────────────────
// 국토교통부 아파트매매 실거래가 자료 (XML)
// https://www.data.go.kr/data/15057511/openapi.do
const _kBaseUrl =
    'https://apis.data.go.kr/1613000/RTMSDataSvcAptTrade/getRTMSDataSvcAptTrade';

/// 국토교통부 아파트 매매 실거래가 서비스.
///
/// [API 스펙]
///   endpoint : $_kBaseUrl
///   인증방식 : Query Parameter — serviceKey (pre-encoded, 수동 URL 조합)
///   응답형식 : XML (공공데이터포털 표준)
///   주요 파라미터:
///     LAWD_CD  — 법정동코드 5자리 (예: 41135 = 경기 성남시 분당구)
///     DEAL_YMD — 계약연월 YYYYMM  (예: 202511)
class PublicDataService {
  const PublicDataService();

  /// 아파트 매매 실거래가 조회.
  ///
  /// - [lawdCd]  : 법정동코드 5자리 (예: '41135')
  /// - [dealYmd] : 계약연월 YYYYMM  (예: '202511')
  Future<AptTradeData> fetchAptTrades({
    required String lawdCd,
    required String dealYmd,
  }) async {
    debugPrint(
      '[PublicDataService] fetchAptTrades — lawdCd: $lawdCd, dealYmd: $dealYmd',
    );

    // .env 키 누락 시 즉시 명확한 예외 — "serviceKey=null" URL 호출 방지
    final serviceKey = dotenv.env['PUBLIC_DATA_KEY'];
    if (serviceKey == null || serviceKey.isEmpty) {
      throw Exception(
        '[PublicDataService] PUBLIC_DATA_KEY가 .env에 설정되지 않았습니다.\n'
        '공공데이터포털(data.go.kr) → 마이페이지 → 일반 인증키(Encoding) 값을 복사하세요.',
      );
    }

    // ⚠️  serviceKey는 이미 퍼센트 인코딩된 값입니다.
    //     Uri.replace(queryParameters:{})를 사용하면 이중 인코딩이 발생하므로
    //     URL 문자열을 직접 조합합니다.
    final url =
        '$_kBaseUrl'
        '?serviceKey=$serviceKey'
        '&LAWD_CD=$lawdCd'
        '&DEAL_YMD=$dealYmd'
        '&numOfRows=30'
        '&pageNo=1';

    debugPrint('[PublicDataService] 요청 URL: $url');
    final res = await http.get(Uri.parse(url));

    if (res.statusCode != 200) {
      debugPrint('[PublicDataService] HTTP ${res.statusCode}: ${res.body}');
      throw Exception('[PublicDataService] HTTP ${res.statusCode}');
    }

    // 공공데이터포털은 오류 시에도 HTTP 200을 반환하고 XML resultCode로 구분합니다.
    final bodyStr = utf8.decode(res.bodyBytes);
    debugPrint('[PublicDataService] 응답 수신 (${bodyStr.length}자)');

    final doc = XmlDocument.parse(bodyStr);

    // resultCode 확인
    final resultCode = doc
        .findAllElements('resultCode')
        .firstOrNull
        ?.innerText
        .trim();
    if (resultCode != null && resultCode != '00' && resultCode != '000') {
      final resultMsg =
          doc.findAllElements('resultMsg').firstOrNull?.innerText.trim() ?? '';
      debugPrint(
        '[PublicDataService] API 오류 — code: $resultCode, msg: $resultMsg',
      );
      throw Exception('API 오류 ($resultCode): $resultMsg');
    }

    final items = doc.findAllElements('item').toList();
    debugPrint('[PublicDataService] 파싱된 거래건수: ${items.length}');

    final records = items.map(AptTradeRecord.fromXml).toList();

    // 단지명은 첫 번째 레코드에서 파생 (API가 단지 메타를 별도 제공하지 않음)
    final complexName = records.isNotEmpty
        ? records.first.complexName
        : '정보 없음';

    return AptTradeData(
      complexName: complexName,
      address: '$lawdCd 일대',
      // 아래 3개 필드는 이 API에서 제공되지 않음 → 0 유지 (UI에서 '-' 표시)
      totalHouseholds: 0,
      buildYear: 0,
      floorAreaRatio: 0,
      records: records,
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// 데이터 모델
// ─────────────────────────────────────────────────────────────────────────────

/// 단지 메타 + 실거래가 목록 통합 응답 모델.
///
/// totalHouseholds · buildYear · floorAreaRatio 는
/// 현재 API에서 미제공 → 값이 0이면 UI에서 '-'로 표시합니다.
class AptTradeData {
  final String complexName;
  final String address;
  final int totalHouseholds; // 총 세대수 (미제공 시 0)
  final int buildYear; // 준공연도  (미제공 시 0)
  final int floorAreaRatio; // 용적률 %  (미제공 시 0)
  final List<AptTradeRecord> records;

  const AptTradeData({
    required this.complexName,
    required this.address,
    required this.totalHouseholds,
    required this.buildYear,
    required this.floorAreaRatio,
    required this.records,
  });
}

/// 개별 실거래 기록.
///
/// [공공 API 응답 XML 필드 매핑]
///   거래금액 → price (만원, 콤마·공백 제거)
///   아파트   → complexName
///   법정동   → dongName
///   전용면적 → area (double)
///   층       → floor
///   건축년도 → buildYear
///   년·월·일 → dealYear, dealMonth, dealDay
class AptTradeRecord {
  final String complexName;
  final String dongName;
  final double area; // 전용면적 (㎡)
  final int floor; // 거래 층
  final int price; // 거래금액 (만원)
  final int dealYear;
  final int dealMonth;
  final int dealDay;
  final int buildYear;

  const AptTradeRecord({
    required this.complexName,
    required this.dongName,
    required this.area,
    required this.floor,
    required this.price,
    required this.dealYear,
    required this.dealMonth,
    required this.dealDay,
    required this.buildYear,
  });

  /// 가격 표시. 예: "9억 5,000만" / "13억 8,000만"
  String get priceLabel {
    final eok = price ~/ 10000;
    final man = price % 10000;
    if (eok > 0 && man > 0) return '$eok억 ${_comma(man)}만';
    if (eok > 0) return '$eok억';
    return '${_comma(price)}만';
  }

  /// 평형 표시. 예: "15평"
  String get pyeongLabel => '${(area / 3.30579).round()}평';

  /// 계약일 표시. 예: "25.11.05"
  String get dealDateStr =>
      '${dealYear.toString().substring(2)}.'
      '${dealMonth.toString().padLeft(2, '0')}.'
      '${dealDay.toString().padLeft(2, '0')}';

  static String _comma(int n) => n.toString().replaceAllMapped(
    RegExp(r'(\d)(?=(\d{3})+(?!\d))'),
    (m) => '${m[1]},',
  );

  /// 공공 API XML → AptTradeRecord 파싱.
  factory AptTradeRecord.fromXml(XmlElement el) {
    String _text(String tag) =>
        el.findElements(tag).firstOrNull?.innerText.trim() ?? '';

    return AptTradeRecord(
      complexName: _text('아파트'),
      dongName: _text('법정동'),
      area: double.tryParse(_text('전용면적')) ?? 0.0,
      floor: int.tryParse(_text('층')) ?? 0,
      price:
          int.tryParse(_text('거래금액').replaceAll(',', '').replaceAll(' ', '')) ??
          0,
      dealYear: int.tryParse(_text('년')) ?? 0,
      dealMonth: int.tryParse(_text('월')) ?? 0,
      dealDay: int.tryParse(_text('일')) ?? 0,
      buildYear: int.tryParse(_text('건축년도')) ?? 0,
    );
  }
}
