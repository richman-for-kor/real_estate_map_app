import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';

import 'apartment_repository.dart' show ApartmentInfo;

/// 관심 매물(찜하기) 단일 아이템 모델.
///
/// Firestore `users/{uid}/favorites/{id}` 문서와 1:1 대응합니다.
class FavoriteItem {
  final String id;       // 문서 ID (kaptCode 또는 단지명 슬러그)
  final String kaptName; // 단지명
  final String kaptAddr; // 주소
  final double lat;
  final double lng;
  final DateTime? savedAt;

  const FavoriteItem({
    required this.id,
    required this.kaptName,
    required this.kaptAddr,
    required this.lat,
    required this.lng,
    this.savedAt,
  });

  /// ApartmentInfo → FavoriteItem.
  factory FavoriteItem.fromApartmentInfo(ApartmentInfo apt) {
    return FavoriteItem(
      id: apt.kaptCode.isNotEmpty ? apt.kaptCode : apt.kaptName,
      kaptName: apt.kaptName,
      kaptAddr: apt.kaptAddr,
      lat: apt.lat,
      lng: apt.lng,
    );
  }

  /// 마커 없는 지도 탭/검색 결과 → FavoriteItem.
  factory FavoriteItem.fromLabel({
    required String label,
    required double lat,
    required double lng,
  }) {
    return FavoriteItem(
      id: label,
      kaptName: label,
      kaptAddr: '',
      lat: lat,
      lng: lng,
    );
  }

  factory FavoriteItem.fromFirestore(
    DocumentSnapshot<Map<String, dynamic>> doc,
  ) {
    final d = doc.data()!;
    return FavoriteItem(
      id: doc.id,
      kaptName: d['kaptName'] as String? ?? '',
      kaptAddr: d['kaptAddr'] as String? ?? '',
      lat: (d['lat'] as num?)?.toDouble() ?? 0.0,
      lng: (d['lng'] as num?)?.toDouble() ?? 0.0,
      savedAt: (d['savedAt'] as Timestamp?)?.toDate(),
    );
  }

  Map<String, dynamic> toFirestore() => {
        'kaptName': kaptName,
        'kaptAddr': kaptAddr,
        'lat': lat,
        'lng': lng,
        'savedAt': FieldValue.serverTimestamp(),
      };
}

/// 관심 매물 비즈니스 로직 서비스.
///
/// Firestore 경로: `users/{uid}/favorites/{id}`
///
/// [사용 예시]
/// ```dart
/// final svc = FavoriteService();
/// await svc.addFavorite(FavoriteItem.fromApartmentInfo(apt));
/// svc.isFavoriteStream('kaptCode').listen((isFav) => ...);
/// ```
class FavoriteService {
  final _auth = FirebaseAuth.instance;
  final _db = FirebaseFirestore.instance;

  /// 현재 로그인 유저의 favorites 컬렉션 레퍼런스.
  /// 비로그인 시 null 반환.
  CollectionReference<Map<String, dynamic>>? _col() {
    final uid = _auth.currentUser?.uid;
    if (uid == null) return null;
    return _db.collection('users').doc(uid).collection('favorites');
  }

  /// 관심 매물 추가. 비로그인 시 silently 무시.
  Future<void> addFavorite(FavoriteItem item) async {
    final col = _col();
    if (col == null) return;
    await col.doc(item.id).set(item.toFirestore());
  }

  /// 관심 매물 삭제.
  Future<void> removeFavorite(String id) async {
    final col = _col();
    if (col == null) return;
    await col.doc(id).delete();
  }

  /// 특정 매물의 관심 등록 여부를 실시간으로 구독.
  Stream<bool> isFavoriteStream(String id) {
    final uid = _auth.currentUser?.uid;
    if (uid == null) return Stream.value(false);
    return _db
        .collection('users')
        .doc(uid)
        .collection('favorites')
        .doc(id)
        .snapshots()
        .map((snap) => snap.exists);
  }

  /// 전체 관심 매물 목록 스트림 (savedAt 내림차순).
  Stream<List<FavoriteItem>> favoritesStream() {
    final uid = _auth.currentUser?.uid;
    if (uid == null) return Stream.value([]);
    return _db
        .collection('users')
        .doc(uid)
        .collection('favorites')
        .orderBy('savedAt', descending: true)
        .snapshots()
        .map(
          (snap) => snap.docs
              .map((d) => FavoriteItem.fromFirestore(d))
              .toList(),
        );
  }

  /// 관심 매물 개수 스트림 (홈/마이페이지 통계 카드용).
  Stream<int> favoriteCountStream() {
    return favoritesStream().map((list) => list.length);
  }
}
