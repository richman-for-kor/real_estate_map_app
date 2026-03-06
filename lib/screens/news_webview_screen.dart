import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';

/// 뉴스 기사 원문을 앱 내에서 렌더링하는 WebView 팝업 스크린.
///
/// [UX] `fullscreenDialog: true`와 함께 사용되어 아래→위 Modal 트랜지션이
/// 적용됩니다. 상단 X 버튼으로 사용자가 즉시 닫을 수 있어 '팝업' UX를 완성합니다.
///
/// [CTO] StatefulWidget으로 WebViewController의 생명주기를 관리합니다.
/// initState에서 1회 생성 후 재사용하므로 불필요한 재빌드가 없습니다.
class NewsWebviewScreen extends StatefulWidget {
  const NewsWebviewScreen({
    super.key,
    required this.url,
    this.title,
  });

  /// 웹뷰에 로드할 완성된 URL 문자열.
  final String url;

  /// AppBar 타이틀. null이면 "부동산 뉴스"로 표시합니다.
  final String? title;

  @override
  State<NewsWebviewScreen> createState() => _NewsWebviewScreenState();
}

class _NewsWebviewScreenState extends State<NewsWebviewScreen> {
  late final WebViewController _controller;
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setNavigationDelegate(
        NavigationDelegate(
          onPageStarted: (_) {
            if (mounted) setState(() => _isLoading = true);
          },
          onPageFinished: (_) {
            if (mounted) setState(() => _isLoading = false);
          },
          onWebResourceError: (_) {
            if (mounted) setState(() => _isLoading = false);
          },
        ),
      )
      ..loadRequest(Uri.parse(widget.url));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      appBar: _buildAppBar(context),
      body: Stack(
        children: [
          WebViewWidget(controller: _controller),
          // 로딩 오버레이: 페이지가 로드되는 동안 부드러운 스피너 표시
          if (_isLoading)
            const Center(
              child: CircularProgressIndicator(
                color: Color(0xFF0A2342), // kPrimary
                strokeWidth: 2.5,
              ),
            ),
        ],
      ),
    );
  }

  /// 클린 화이트 AppBar — X 닫기 버튼 + "부동산 뉴스" 타이틀.
  ///
  /// [UX] elevation: 0 + surfaceTintColor: transparent 으로 스크롤 시
  /// Material 3의 자동 색조(tint) 변화를 억제하여 항상 순백을 유지합니다.
  /// bottom의 1px 구분선은 AppBar와 콘텐츠 경계를 명확히 해 줍니다.
  PreferredSizeWidget _buildAppBar(BuildContext context) {
    return AppBar(
      backgroundColor: Colors.white,
      elevation: 0,
      surfaceTintColor: Colors.transparent,
      // X 닫기 버튼 — fullscreenDialog Modal의 핵심 탈출구
      leading: IconButton(
        icon: const Icon(Icons.close_rounded, color: Color(0xFF0D1B2A)),
        tooltip: '닫기',
        onPressed: () => Navigator.pop(context),
      ),
      title: Text(
        widget.title ?? '부동산 뉴스',
        style: const TextStyle(
          fontSize: 15,
          fontWeight: FontWeight.w600,
          color: Color(0xFF0D1B2A), // kTextDark
          letterSpacing: -0.2,
        ),
      ),
      centerTitle: true,
      // AppBar 하단 구분선
      bottom: PreferredSize(
        preferredSize: const Size.fromHeight(1),
        child: Container(height: 1, color: const Color(0xFFDDE3EA)), // kBorderColor
      ),
    );
  }
}
