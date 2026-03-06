import 'dart:convert';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

// ─────────────────────────────────────────────────────────────────────────────
// NewsItem — 불변 데이터 모델
// ─────────────────────────────────────────────────────────────────────────────

/// 네이버 뉴스 검색 API 응답 단건 모델.
///
/// [CTO] 불변(immutable) 값 객체. 생성 시점에 HTML 정제가 완료되므로
/// UI 레이어에서 별도 처리 없이 바로 렌더링 가능합니다.
class NewsItem {
  const NewsItem({
    required this.title,
    required this.description,
    required this.link,
    required this.originallink,
    required this.pubDate,
  });

  final String title;
  final String description;

  /// 네이버 뉴스 페이지 링크 (originallink가 없을 때 fallback).
  final String link;

  /// 기사 원문 언론사 링크.
  final String originallink;

  final DateTime pubDate;

  // ── Computed properties ───────────────────────────────────────────────────

  /// 기사를 열 때 사용할 URL. 원문 링크 우선, 없으면 네이버 뉴스 링크 사용.
  String get openUrl => originallink.isNotEmpty ? originallink : link;

  /// 출처 도메인. originallink URL에서 호스트명만 추출합니다.
  ///
  /// 예) "https://www.hankyung.com/..." → "hankyung.com"
  String get source {
    try {
      final host = Uri.parse(originallink).host;
      return host.startsWith('www.') ? host.substring(4) : host;
    } catch (_) {
      return '네이버 뉴스';
    }
  }

  /// 현재 시각 기준 상대 시간 표시.
  ///
  /// 예) "5분 전", "3시간 전", "어제", "3일 전"
  String get relativeTime {
    final diff = DateTime.now().difference(pubDate);
    if (diff.inMinutes < 1) return '방금';
    if (diff.inMinutes < 60) return '${diff.inMinutes}분 전';
    if (diff.inHours < 24) return '${diff.inHours}시간 전';
    if (diff.inDays == 1) return '어제';
    return '${diff.inDays}일 전';
  }

  /// 제목 키워드 기반 태그 자동 분류.
  ///
  /// [PM] 검색어("부동산 OR 아파트 청약")로 시세·청약 이슈를 모두 커버하므로
  /// 제목 키워드로 태그를 분류하여 시각적 카테고리 구분을 제공합니다.
  String get tag {
    if (title.contains('청약')) return '청약';
    if (title.contains('대출') || title.contains('DSR') || title.contains('금리'))
      return '대출';
    if (title.contains('재건축') ||
        title.contains('재개발') ||
        title.contains('정책') ||
        title.contains('규제') ||
        title.contains('법'))
      return '정책';
    if (title.contains('전세') || title.contains('월세')) return '전월세';
    return '시세';
  }

  factory NewsItem.fromJson(Map<String, dynamic> json) {
    return NewsItem(
      title: _stripHtml(json['title'] as String? ?? ''),
      description: _stripHtml(json['description'] as String? ?? ''),
      link: json['link'] as String? ?? '',
      originallink: json['originallink'] as String? ?? '',
      pubDate: _parsePubDate(json['pubDate'] as String? ?? ''),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// 데이터 정제 헬퍼 함수
// ─────────────────────────────────────────────────────────────────────────────

/// HTML 태그 및 엔티티 정제.
///
/// [FE 리드] 네이버 뉴스 API는 title·description에 <b>, &quot; 등
/// 원시 HTML을 그대로 포함합니다.
/// 1단계: 정규식으로 모든 HTML 태그 제거
/// 2단계: 빈출 HTML 엔티티를 문자로 디코딩
String _stripHtml(String raw) {
  // 1단계: <b>, </b>, <br />, <strong> 등 모든 태그 제거
  var text = raw.replaceAll(RegExp(r'<[^>]+>'), '');

  // 2단계: 네이버 API에서 자주 등장하는 HTML 엔티티 디코딩
  text = text
      .replaceAll('&quot;', '"')
      .replaceAll('&#34;', '"')
      .replaceAll('&amp;', '&')
      .replaceAll('&#38;', '&')
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&apos;', "'")
      .replaceAll('&#39;', "'")
      .replaceAll('&nbsp;', ' ');

  return text.trim();
}

/// RFC 822 형식 pubDate를 DateTime으로 파싱.
///
/// 네이버 API 예시: "Thu, 27 Feb 2026 10:00:00 +0900"
/// Dart의 DateTime.parse()는 ISO 8601만 지원하므로 수동 변환합니다.
DateTime _parsePubDate(String raw) {
  try {
    const months = {
      'Jan': '01',
      'Feb': '02',
      'Mar': '03',
      'Apr': '04',
      'May': '05',
      'Jun': '06',
      'Jul': '07',
      'Aug': '08',
      'Sep': '09',
      'Oct': '10',
      'Nov': '11',
      'Dec': '12',
    };

    // "Thu, 27 Feb 2026 10:00:00 +0900" → 공백으로 분리
    final parts = raw.trim().split(RegExp(r'\s+'));
    if (parts.length < 6) return DateTime.now();

    final day = parts[1].padLeft(2, '0');
    final month = months[parts[2]] ?? '01';
    final year = parts[3];
    final time = parts[4];
    final tzRaw = parts[5]; // "+0900", "-0500" 등

    // 타임존 오프셋 파싱 — tzDigits 길이 부족 시 RangeError 방어
    final sign = tzRaw.startsWith('-') ? -1 : 1;
    final tzDigits = tzRaw.replaceAll('+', '').replaceAll('-', '');
    if (tzDigits.length < 4) return DateTime.now();
    final tzHours = int.tryParse(tzDigits.substring(0, 2)) ?? 0;
    final tzMins = int.tryParse(tzDigits.substring(2, 4)) ?? 0;

    // naive DateTime으로 파싱 후 UTC 기준으로 변환
    final naive = DateTime.parse('$year-$month-${day}T$time');
    return naive.subtract(
      Duration(hours: tzHours * sign, minutes: tzMins * sign),
    );
  } catch (_) {
    return DateTime.now();
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// NewsService
// ─────────────────────────────────────────────────────────────────────────────

/// 네이버 뉴스 검색 API 서비스.
///
/// [CTO] 클라이언트에서 직접 호출하는 단순 GET 래퍼.
/// 실 서비스 규모 확장 시 서버사이드 캐싱 레이어(Cloud Functions 등)를 권장합니다.
class NewsService {
  // [PM] 직관적 키워드로 최신 부동산 뉴스를 정확하게 타겟팅합니다.
  static const _query = '분당 아파트 부동산';

  /// 부동산 관련 최신 뉴스 10건을 반환합니다.
  ///
  /// [CTO] Uri.replace()의 queryParameters는 내부적으로 form-encoding을 적용하므로
  /// 한글 검색어가 올바르게 인코딩되지 않는 경우가 있습니다.
  /// Uri.encodeComponent()로 직접 인코딩한 쿼리 스트링을 Uri.parse()에 전달하여
  /// sort=date가 100% 포함됨을 보장합니다.
  Future<List<NewsItem>> fetchNews() async {
    final encodedQuery = Uri.encodeComponent(_query);
    final uri = Uri.parse(
      'https://openapi.naver.com/v1/search/news.json'
      '?query=$encodedQuery&display=10&sort=date',
    );

    // ─────────────────────────────────────────────────────────────────────────────
    // [CTO] 네이버 검색 API 인증 키
    //
    // 👉 발급 위치: https://developers.naver.com → 내 애플리케이션 → 등록한 앱 선택
    //              → [개요] 탭 → Client ID / Client Secret
    // ─────────────────────────────────────────────────────────────────────────────
    final response = await http.get(
      uri,
      headers: {
        'X-Naver-Client-Id': dotenv.env['NAVER_CLIENT_ID'] ?? '',
        'X-Naver-Client-Secret': dotenv.env['NAVER_CLIENT_SECRET'] ?? '',
      },
    );

    // [디버깅] 터미널에서 API 인증·응답 성공 여부를 즉시 확인합니다.
    debugPrint('[NewsService] 뉴스 API 응답 코드: ${response.statusCode}');

    if (response.statusCode != 200) {
      throw Exception('뉴스를 불러오지 못했습니다 (HTTP ${response.statusCode})');
    }

    // utf8.decode(bodyBytes) — response.body는 latin-1 기본 디코딩으로 한글이 깨질 수 있음
    final data =
        jsonDecode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>;
    final items = data['items'] as List<dynamic>;
    return items
        .map((e) => NewsItem.fromJson(e as Map<String, dynamic>))
        .toList();
  }
}
