import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import '../main.dart'
    show kPrimary, kPrimaryLight, kSurface, kBackground, kTextDark, kTextMuted;
import '../services/recent_view_service.dart';

/// 최근 본 매물 목록 화면.
class RecentViewScreen extends StatelessWidget {
  const RecentViewScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<User?>(
      stream: FirebaseAuth.instance.authStateChanges(),
      builder: (context, authSnap) {
        if (authSnap.data == null) {
          return _buildLoginRequired(context);
        }
        return _RecentViewBody();
      },
    );
  }

  Widget _buildLoginRequired(BuildContext context) {
    return Scaffold(
      backgroundColor: kBackground,
      appBar: AppBar(title: const Text('최근 본 매물')),
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              width: 80,
              height: 80,
              decoration: const BoxDecoration(
                color: kPrimaryLight,
                shape: BoxShape.circle,
              ),
              child: const Icon(Icons.history_rounded, size: 40, color: kPrimary),
            ),
            const SizedBox(height: 20),
            const Text(
              '로그인이 필요합니다',
              style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700, color: kTextDark),
            ),
            const SizedBox(height: 8),
            const Text(
              '로그인하면 최근 본 매물을\n다시 확인할 수 있어요.',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 13.5, color: kTextMuted, height: 1.6),
            ),
          ],
        ),
      ),
    );
  }
}

class _RecentViewBody extends StatelessWidget {
  final _svc = RecentViewService();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: kBackground,
      appBar: AppBar(
        title: const Text('최근 본 매물'),
        backgroundColor: kSurface,
        elevation: 0,
        scrolledUnderElevation: 0,
      ),
      body: StreamBuilder<List<RecentViewItem>>(
        stream: _svc.recentViewsStream(),
        builder: (context, snap) {
          if (snap.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator(color: kPrimary));
          }
          final items = snap.data ?? [];
          if (items.isEmpty) {
            return Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Container(
                    width: 80,
                    height: 80,
                    decoration: const BoxDecoration(
                      color: kPrimaryLight,
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(Icons.history_rounded, size: 40, color: kPrimary),
                  ),
                  const SizedBox(height: 20),
                  const Text(
                    '최근 본 매물이 없어요',
                    style: TextStyle(
                      fontSize: 17,
                      fontWeight: FontWeight.w700,
                      color: kTextDark,
                    ),
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    '지도에서 아파트 마커를 탭하면\n자동으로 기록됩니다.',
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 13.5, color: kTextMuted, height: 1.6),
                  ),
                ],
              ),
            );
          }

          return ListView.separated(
            padding: const EdgeInsets.all(20),
            itemCount: items.length,
            separatorBuilder: (context, index) => const SizedBox(height: 10),
            itemBuilder: (context, i) => _RecentViewCard(item: items[i]),
          );
        },
      ),
    );
  }
}

class _RecentViewCard extends StatelessWidget {
  const _RecentViewCard({required this.item});
  final RecentViewItem item;

  String _formatDate(DateTime dt) {
    final m = dt.month.toString().padLeft(2, '0');
    final d = dt.day.toString().padLeft(2, '0');
    final h = dt.hour.toString().padLeft(2, '0');
    final min = dt.minute.toString().padLeft(2, '0');
    return '$m.$d $h:$min';
  }

  @override
  Widget build(BuildContext context) {
    final dateStr = item.viewedAt != null ? _formatDate(item.viewedAt!) : '';
    return Container(
      decoration: BoxDecoration(
        color: kSurface,
        borderRadius: BorderRadius.circular(16),
        boxShadow: const [
          BoxShadow(color: Color(0x0F000000), blurRadius: 16, offset: Offset(0, 4)),
        ],
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        child: Row(
          children: [
            Container(
              width: 44,
              height: 44,
              decoration: const BoxDecoration(
                color: kPrimaryLight,
                shape: BoxShape.circle,
              ),
              child: const Icon(Icons.apartment_rounded, color: kPrimary, size: 22),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    item.name,
                    style: const TextStyle(
                      fontSize: 14.5,
                      fontWeight: FontWeight.w600,
                      color: kTextDark,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  if (item.address.isNotEmpty) ...[
                    const SizedBox(height: 3),
                    Text(
                      item.address,
                      style: const TextStyle(fontSize: 12, color: kTextMuted),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ],
              ),
            ),
            if (dateStr.isNotEmpty)
              Text(
                dateStr,
                style: const TextStyle(fontSize: 11, color: kTextMuted),
              ),
            const SizedBox(width: 4),
            const Icon(Icons.chevron_right_rounded, color: kTextMuted, size: 18),
          ],
        ),
      ),
    );
  }
}
