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
class _TimedCache<T> {
  _TimedCache(this.ttl);

  final Duration ttl;
  final Map<String, _CacheEntry<T>> _store = {};

  bool has(String key) {
    final e = _store[key];
    return e != null && DateTime.now().difference(e.at) < ttl;
  }

  T? read(String key) {
    if (!has(key)) return null;
    return _store[key]!.value;
  }

  void write(String key, T value) {
    _store[key] = _CacheEntry(value, DateTime.now());
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// 데이터 모델
// ─────────────────────────────────────────────────────────────────────────────

/// 개별 실거래 기록.
/// apartment_trades/{aptCode}.tradesByArea.{평형라벨}[] 배열 항목과 1:1 대응.
class TradeRecord {
  const TradeRecord({
    required this.areaLabel,
    required this.date,
    required this.price,
    required this.floor,
    required this.netArea,
  });

  /// 평형 라벨 (예: "34평", "24평")
  final String areaLabel;

  /// 계약일 문자열 YYYYMMDD (예: "20240115")
  final String date;

  /// 거래금액 (만원)
  final int price;

  final int floor;

  /// 전용면적 (㎡)
  final double netArea;

  // ── Computed Properties ──────────────────────────────────────────────────

  DateTime get dateTime {
    if (date.length >= 8) {
      final y = int.tryParse(date.substring(0, 4)) ?? 2000;
      final m = int.tryParse(date.substring(4, 6)) ?? 1;
      final d = int.tryParse(date.substring(6, 8)) ?? 1;
      return DateTime(y, m, d);
    }
    return DateTime(2000);
  }

  /// 평형 수치 (예: "34평" → 34)
  int get pyeong => int.tryParse(areaLabel.replaceAll('평', '')) ?? 0;

  /// 전용면적: netArea 우선, 없으면 평형 역산
  double get area => netArea > 0 ? netArea : pyeong * 3.30579;

  /// 가격 표시. 예: "9억 5,000만" / "13억"
  String get priceLabel {
    final eok = price ~/ 10000;
    final man = price % 10000;
    if (eok > 0 && man > 0) return '$eok억 ${_comma(man)}만';
    if (eok > 0) return '$eok억';
    return '${_comma(price)}만';
  }

  /// 계약일 표시. 예: "25.11.05"
  String get dealDateStr {
    final dt = dateTime;
    final yy = dt.year.toString().substring(2);
    final mm = dt.month.toString().padLeft(2, '0');
    final dd = dt.day.toString().padLeft(2, '0');
    return '$yy.$mm.$dd';
  }

  static String _comma(int n) => n.toString().replaceAllMapped(
        RegExp(r'(\d)(?=(\d{3})+(?!\d))'),
        (m) => '${m[1]},',
      );

  factory TradeRecord.fromMap(Map<String, dynamic> m, String areaLabel) =>
      TradeRecord(
        areaLabel: areaLabel,
        date: m['date']?.toString() ?? '',
        price: (m['price'] as num?)?.toInt() ?? 0,
        floor: (m['floor'] as num?)?.toInt() ?? 0,
        netArea: (m['netArea'] as num?)?.toDouble() ?? 0.0,
      );
}

// ─────────────────────────────────────────────────────────────────────────────
// TradeRepository — apartment_trades Firestore 조회 + 인메모리 캐싱
// ─────────────────────────────────────────────────────────────────────────────

/// apartment_trades/{aptCode} 문서에서 10년치 실거래 데이터를 조회.
///
/// [Firestore Read 최소화 전략]
///   1. 인메모리 캐시 (_TimedCache) — TTL 6시간, 동일 단지 반복 탭 시 미조회
///   2. In-flight 중복 방지 — 시세 탭 빠른 재개방 시 동시 요청 합산
class TradeRepository {
  TradeRepository._();
  static final TradeRepository instance = TradeRepository._();

  final _db = FirebaseFirestore.instance;

  // TTL 6시간: 배치가 하루 1~2회 갱신된다면 6시간이면 충분.
  // 더 신선한 데이터가 필요하면 TTL을 줄이세요.
  final _cache = _TimedCache<List<TradeRecord>>(const Duration(hours: 6));

  // In-flight: 시세 탭을 빠르게 닫았다 다시 열어도 Firestore 1회만 조회.
  final Map<String, Future<List<TradeRecord>>> _inflight = {};

  /// aptCode에 해당하는 전체 실거래 목록 반환.
  /// 반환값: 모든 평형의 거래 기록을 평탄화한 리스트.
  Future<List<TradeRecord>> getTradesByAptCode(String aptCode) async {
    if (aptCode.isEmpty) return [];

    // 1. 메모리 캐시 확인
    final cached = _cache.read(aptCode);
    if (cached != null) {
      debugPrint('[TradeRepo] 캐시 HIT — $aptCode (${cached.length}건)');
      return cached;
    }

    // 2. In-flight 합산
    return _inflight.putIfAbsent(aptCode, () async {
      debugPrint('[TradeRepo] Firestore 실거래 조회 — aptCode: $aptCode');
      try {
        final doc =
            await _db.collection('apartment_trades').doc(aptCode).get();

        if (!doc.exists) {
          debugPrint('[TradeRepo] 실거래 문서 없음 — $aptCode');
          _cache.write(aptCode, []); // 없는 문서도 캐시 → 재조회 방지
          return [];
        }

        final data = doc.data()!;
        final tradesByArea = data['tradesByArea'];
        if (tradesByArea is! Map) {
          debugPrint('[TradeRepo] tradesByArea 필드 없음 — $aptCode');
          _cache.write(aptCode, []);
          return [];
        }

        final records = <TradeRecord>[];
        for (final entry in tradesByArea.entries) {
          final label = entry.key.toString();
          final list = entry.value;
          if (list is! List) continue;
          for (final item in list) {
            if (item is Map<String, dynamic>) {
              final r = TradeRecord.fromMap(item, label);
              if (r.price > 0) records.add(r);
            }
          }
        }

        debugPrint('[TradeRepo] ✅ ${records.length}건 실거래 로드 — $aptCode');
        _cache.write(aptCode, records);
        return records;
      } catch (e) {
        debugPrint('[TradeRepo] 실거래 조회 오류: $e');
        // 오류 시 캐시 안 함 → 다음 요청 시 재시도
        return [];
      } finally {
        _inflight.remove(aptCode);
      }
    });
  }
}
