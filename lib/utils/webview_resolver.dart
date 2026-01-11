import 'dart:async';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

class WebviewResolver {
  HeadlessInAppWebView? _headlessWebView;
  
  /// 启动隐形浏览器解析链接
  Future<String?> resolveUrl(String url) async {
    Completer<String?> completer = Completer();
    
    print("🕵️ [WebView] 启动隐形侦察机: $url");

    try {
      _headlessWebView = HeadlessInAppWebView(
        initialUrlRequest: URLRequest(url: WebUri(url)),
        initialSettings: InAppWebViewSettings(
          userAgent: "Mozilla/5.0 (iPhone; CPU iPhone OS 16_6 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/16.6 Mobile/15E148 Safari/604.1", // 伪装成 iPhone Safari
          javaScriptEnabled: true, // 开启 JS，这是成功的关键
          useShouldOverrideUrlLoading: true,
        ),
        onLoadStart: (controller, url) {
          _checkUrl(url, completer);
        },
        onLoadStop: (controller, url) {
          _checkUrl(url, completer);
        },
        onUpdateVisitedHistory: (controller, url, androidIsReload) {
          _checkUrl(url, completer);
        },
        onConsoleMessage: (controller, consoleMessage) {
          // 可选：监听控制台日志调试
        },
      );

      // 运行浏览器
      await _headlessWebView?.run();
      
      // 设置超时，防止无限等待 (15秒超时)
      return await completer.future.timeout(const Duration(seconds: 15), onTimeout: () {
        print("⏰ [WebView] 解析超时");
        return null;
      });

    } catch (e) {
      print("❌ [WebView] 错误: $e");
      return null;
    } finally {
      // 销毁浏览器，释放内存
      _headlessWebView?.dispose();
      _headlessWebView = null;
    }
  }

  void _checkUrl(WebUri? webUri, Completer<String?> completer) {
    if (webUri == null || completer.isCompleted) return;
    
    String url = webUri.toString();
    print("👉 [WebView跳转] $url");

    // 1. 匹配 m.weibo.cn/status/xxx
    RegExp regStatus = RegExp(r'status(?:es)?\/(\d+)');
    var m1 = regStatus.firstMatch(url);
    if (m1 != null) {
      print("✅ [WebView] 捕获 ID: ${m1.group(1)}");
      completer.complete(m1.group(1));
      return;
    }

    // 2. 匹配 weibo.cn/detail/xxx
    RegExp regDetail = RegExp(r'detail\/(\d+)');
    var m2 = regDetail.firstMatch(url);
    if (m2 != null) {
      print("✅ [WebView] 捕获 ID: ${m2.group(1)}");
      completer.complete(m2.group(1));
      return;
    }
    
    // 3. 匹配 weibo_id=xxx
    RegExp regParam = RegExp(r'weibo_id=(\d+)');
    var m3 = regParam.firstMatch(url);
    if (m3 != null) {
       print("✅ [WebView] 捕获 ID: ${m3.group(1)}");
       completer.complete(m3.group(1));
       return;
    }
  }
}