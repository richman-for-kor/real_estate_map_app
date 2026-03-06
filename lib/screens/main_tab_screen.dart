import 'package:flutter/material.dart';
import '../main.dart' show kPrimary, kSurface, kTextMuted;
import 'home_screen.dart';
import 'map_screen.dart';
import 'imjang_screen.dart';
import 'my_page_screen.dart';

/// 앱의 루트 화면. Bottom Navigation + IndexedStack 4탭 구조.
///
/// [PM] Deferred Auth 전략의 핵심.
/// 앱 진입 시 강제 로그인 없이 모든 탭에 즉시 접근 가능합니다.
///
/// [CTO] _screens를 initState()에서 한 번만 생성합니다.
/// - IndexedStack이 State를 보존하기 때문에 Widget 인스턴스가 불변이어야 합니다.
/// - HomeScreen에 onTabSwitch 콜백을 전달하여 탭 간 직접 이동을 지원합니다.
///   (콜백 때문에 HomeScreen은 const 불가 → 반드시 initState에서 생성)
class MainTabScreen extends StatefulWidget {
  const MainTabScreen({super.key});

  @override
  State<MainTabScreen> createState() => _MainTabScreenState();
}

class _MainTabScreenState extends State<MainTabScreen> {
  int _currentIndex = 0;

  // [CTO] late final: initState에서 1회 생성 후 build()에서 재생성되지 않음.
  // HomeScreen이 onTabSwitch 콜백을 포함하므로 const 불가 → initState 초기화 필수.
  late final List<Widget> _screens;

  @override
  void initState() {
    super.initState();
    _screens = [
      HomeScreen(onTabSwitch: _switchTab), // 콜백 전달
      const MapScreen(),
      const ImjangScreen(),
      const MyPageScreen(),
    ];
  }

  void _switchTab(int index) => setState(() => _currentIndex = index);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: IndexedStack(
        index: _currentIndex,
        children: _screens,
      ),
      bottomNavigationBar: _buildBottomNavBar(),
    );
  }

  Widget _buildBottomNavBar() {
    return Container(
      decoration: BoxDecoration(
        color: kSurface,
        border: Border(
          top: BorderSide(color: Colors.grey.shade200, width: 1),
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.06),
            blurRadius: 12,
            offset: const Offset(0, -3),
          ),
        ],
      ),
      child: BottomNavigationBar(
        currentIndex: _currentIndex,
        onTap: _switchTab,
        type: BottomNavigationBarType.fixed,
        backgroundColor: Colors.transparent,
        elevation: 0,
        selectedItemColor: kPrimary,
        unselectedItemColor: kTextMuted,
        selectedFontSize: 10.5,
        unselectedFontSize: 10.5,
        selectedLabelStyle: const TextStyle(fontWeight: FontWeight.w700),
        unselectedLabelStyle: const TextStyle(fontWeight: FontWeight.w400),
        items: const [
          BottomNavigationBarItem(
            icon: Padding(
              padding: EdgeInsets.only(bottom: 2),
              child: Icon(Icons.home_outlined, size: 24),
            ),
            activeIcon: Padding(
              padding: EdgeInsets.only(bottom: 2),
              child: Icon(Icons.home_rounded, size: 24),
            ),
            label: '홈',
          ),
          BottomNavigationBarItem(
            icon: Padding(
              padding: EdgeInsets.only(bottom: 2),
              child: Icon(Icons.map_outlined, size: 24),
            ),
            activeIcon: Padding(
              padding: EdgeInsets.only(bottom: 2),
              child: Icon(Icons.map_rounded, size: 24),
            ),
            label: '지도',
          ),
          BottomNavigationBarItem(
            icon: Padding(
              padding: EdgeInsets.only(bottom: 2),
              child: Icon(Icons.edit_note_outlined, size: 26),
            ),
            activeIcon: Padding(
              padding: EdgeInsets.only(bottom: 2),
              child: Icon(Icons.edit_note_rounded, size: 26),
            ),
            label: '임장노트',
          ),
          BottomNavigationBarItem(
            icon: Padding(
              padding: EdgeInsets.only(bottom: 2),
              child: Icon(Icons.person_outline_rounded, size: 24),
            ),
            activeIcon: Padding(
              padding: EdgeInsets.only(bottom: 2),
              child: Icon(Icons.person_rounded, size: 24),
            ),
            label: '내 정보',
          ),
        ],
      ),
    );
  }
}
