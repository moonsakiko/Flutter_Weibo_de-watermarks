import 'package:dio/dio.dart';
import 'package:path_provider/path_provider.dart';
import 'dart:io';
import 'webview_resolver.dart'; // 引入新文件

class WeiboApi {
  // 基础 Header，用于获取图片列表
  static const Map<String, String> _headers = {
    'User-Agent': 'Mozilla/5.0 (iPhone; CPU iPhone OS 13_2_3 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/13.0.3 Mobile/15E148 Safari/604.1',
    'Accept': 'application/json, text/plain, */*',
    'X-Requested-With': 'XMLHttpRequest',
  };

  /// 🛠️ 从文本中提取链接
  static String? extractUrlFromText(String text) {
    RegExp regExp = RegExp(r'(https?://[a-zA-Z0-9\.\/\-\_\?\=\&\%\#]+)');
    var match = regExp.firstMatch(text);
    return match?.group(0);
  }

  /// 🆔 获取 Weibo ID (融合了 WebView 强力解析)
  static Future<String?> getWeiboId(String rawText) async {
    // 1. 提取链接
    String? url = extractUrlFromText(rawText);
    if (url == null) return null;

    print("🔍 解析目标: $url");

    // 2. 如果是简单链接，直接正则提取，速度快
    String? fastId = _regexId(url);
    if (fastId != null) return fastId;

    // 3. ⚠️ 遇到困难链接 (mapp/share/t.cn)，启动隐形浏览器解析
    // 这是最慢但最稳的方法
    WebviewResolver resolver = WebviewResolver();
    String? webviewId = await resolver.resolveUrl(url);
    
    return webviewId;
  }

  static String? _regexId(String url) {
    if (url.contains("status")) {
      RegExp reg = RegExp(r'status(?:es)?\/(\d+)');
      return reg.firstMatch(url)?.group(1);
    }
    return null;
  }

  /// 🖼️ 获取图片列表 (逻辑不变)
  static Future<List<Map<String, String>>> getImageUrls(String weiboId) async {
    final url = "https://m.weibo.cn/statuses/show?id=$weiboId";
    Dio dio = Dio();
    dio.options.headers = _headers; 
    
    try {
      print("📡 请求微博API: $url");
      final response = await dio.get(url);
      
      if (response.statusCode == 200) {
        final data = response.data;
        List? pics;
        if (data is Map) {
          if (data['pics'] != null) pics = data['pics'];
          else if (data['data'] != null && data['data']['pics'] != null) pics = data['data']['pics'];
        }

        if (pics == null) return [];

        List<Map<String, String>> results = [];
        for (var pic in pics) {
          String url = pic['large']['url'];
          
          String wmUrl = url.replaceAll(RegExp(r'(\/orj360\/|\/oslarge\/|\/mw690\/|\/thumbnail\/|\/bmiddle\/|\/thumb180\/)'), '/large/');
          String origUrl = url.replaceAll(RegExp(r'(\/orj360\/|\/large\/|\/mw690\/|\/thumbnail\/|\/bmiddle\/|\/thumb180\/)'), '/oslarge/');
          
          String filename = url.split('/').last.split('?').first.split('.').first;
          String ext = ".${url.split('.').last.split('?').first}";

          results.add({
            'wm_url': wmUrl,
            'orig_url': origUrl,
            'filename': filename,
            'ext': ext
          });
        }
        return results;
      }
    } catch (e) {
      print("❌ API Error: $e");
    }
    return [];
  }

  static Future<Map<String, String>?> downloadPair(Map<String, String> item, Function(String) onLog) async {
    Dio dio = Dio();
    dio.options.headers = _headers; 
    
    Directory tempDir = await getTemporaryDirectory();
    String baseName = item['filename']!;
    String ext = item['ext']!;
    String wmPath = "${tempDir.path}/$baseName-wm$ext";
    String origPath = "${tempDir.path}/$baseName-orig$ext";

    try {
      await Future.wait([
        dio.download(item['wm_url']!, wmPath),
        dio.download(item['orig_url']!, origPath)
      ]);
      return {'wm': wmPath, 'clean': origPath};
    } catch (e) {
      onLog("❌ 下载失败 (${item['filename']}): ${e.toString()}");
      return null;
    }
  }
}