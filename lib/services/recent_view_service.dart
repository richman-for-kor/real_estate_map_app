import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';

/// 최근 본 매물 추적 서비스.
///
/// Firestore 경로: `users/{uid}/recent_views/{id}`
/// - 지도 팝업(PropertyInfoSheet)을 열 때 자동 저장
/// - 최대 30건 유지 (오래된 것 자동 삭제)
/// - 비로그인 시 silently 무시
class RecentViewService {
  final _auth = FirebaseAuth.instance;
  final _db = FirebaseFirestore.instance;

  CollectionReference<Map<String, dynamic>>? _col() {
    final uid = _auth.currentUser?.uid;
    if (uid == null) return null;
    return _db.collection('users').doc(uid).collection('recent_views');
  }

  /// 최근 본 매물에 추가/갱신.
  ///
  /// 이미 있으면 viewedAt만 갱신 (중복 방지).
  Future<void> addView({
    required String id,
    required String name,
    required String address,
    required double lat,
    required double lng,
  }) async {
    final col = _col();
    if (col == null) return;
    try {
      await col.doc(id).set({
        'name': name,
        'address': address,
        'lat': lat,
        'lng': lng,
        'viewedAt': FieldValue.serverTimestamp(),
      });
      // 30건 초과 시 가장 오래된 항목 삭제
      final snap = await col.orderBy('viewedAt', descending: true).get();
      if (snap.docs.length > 30) {
        for (final doc in snap.docs.sublist(30)) {
          doc.reference.delete();
        }
      }
    } catch (_) {}
  }

  /// 최근 본 매물 목록 스트림 (최신순 30건).
  Stream<List<RecentViewItem>> recentViewsStream() {
    final uid = _auth.currentUser?.uid;
    if (uid == null) return Stream.value([]);
    return _db
        .collection('users')
        .doc(uid)
        .collection('recent_views')
        .orderBy('viewedAt', descending: true)
        .limit(30)
        .snapshots()
        .map((snap) => snap.docs.map(RecentViewItem.fromDoc).toList());
  }

  /// 최근 본 매물 개수 스트림 (통계 카드용).
  Stream<int> recentViewCountStream() =>
      recentViewsStream().map((list) => list.length);
}

class RecentViewItem {
  final String id;
  final String name;
  final String address;
  final double lat;
  final double lng;
  final DateTime? viewedAt;

  const RecentViewItem({
    required this.id,
    required this.name,
    required this.address,
    required this.lat,
    required this.lng,
    this.viewedAt,
  });

  factory RecentViewItem.fromDoc(
      DocumentSnapshot<Map<String, dynamic>> doc) {
    final d = doc.data()!;
    return RecentViewItem(
      id: doc.id,
      name: d['name'] as String? ?? '',
      address: d['address'] as String? ?? '',
      lat: (d['lat'] as num?)?.toDouble() ?? 0.0,
      lng: (d['lng'] as num?)?.toDouble() ?? 0.0,
      viewedAt: (d['viewedAt'] as Timestamp?)?.toDate(),
    );
  }
}
