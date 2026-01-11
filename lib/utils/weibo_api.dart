import 'package:dio/dio.dart';
import 'package:path_provider/path_provider.dart';
import 'dart:io';

class WeiboApi {
  static const Map<String, String> _baseHeaders = {
    'User-Agent': 'Mozilla/5.0 (iPhone; CPU iPhone OS 16_6 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/16.6 Mobile/15E148 Safari/604.1',
    'Accept': 'application/json, text/plain, */*',
    'X-Requested-With': 'XMLHttpRequest',
  };

  /// 🛠️ 宽容的链接提取
  static String? extractUrlFromText(String text) {
    RegExp regExp = RegExp(r'(https?://[a-zA-Z0-9\.\/\-\_\?\=\&\%\#]+)');
    var match = regExp.firstMatch(text);
    if (match != null) return match.group(0);
    if (text.contains("weibo.cn") || text.contains("t.cn") || text.contains("weibo.com")) {
      String clean = text.replaceAll(RegExp(r'\s+'), '');
      if (!clean.startsWith("http")) return "https://$clean";
      return clean;
    }
    return null;
  }

  /// 🆔 纯正则提取 ID
  static String? parseIdFromUrl(String url) {
    RegExp regStatus = RegExp(r'status(?:es)?\/(\d+)');
    var m1 = regStatus.firstMatch(url);
    if (m1 != null) return m1.group(1);

    RegExp regDetail = RegExp(r'detail\/(\d+)');
    var m2 = regDetail.firstMatch(url);
    if (m2 != null) return m2.group(1);

    RegExp regParam = RegExp(r'weibo_id=(\d+)');
    var m3 = regParam.firstMatch(url);
    if (m3 != null) return m3.group(1);

    return null;
  }

  /// 🖼️ 获取图片列表 (支持 Cookie 注入 + 双接口备选)
  static Future<List<Map<String, String>>> getImageUrls(String weiboId, {String? cookie}) async {
    Dio dio = Dio();
    // 注入 Cookie，伪装成浏览器
    Map<String, String> headers = Map.from(_baseHeaders);
    if (cookie != null && cookie.isNotEmpty) {
      headers['Cookie'] = cookie;
      // print("🍪 注入 Cookie: ${cookie.substring(0, 20)}...");
    }
    dio.options.headers = headers;

    // 策略 A: 标准接口
    String urlA = "https://m.weibo.cn/statuses/show?id=$weiboId";
    List<Map<String, String>> resultA = await _tryFetch(dio, urlA, "API-A");
    if (resultA.isNotEmpty) return resultA;

    // 策略 B: 扩展接口 (针对长微博/新版微博)
    String urlB = "https://m.weibo.cn/statuses/extend?id=$weiboId";
    List<Map<String, String>> resultB = await _tryFetch(dio, urlB, "API-B");
    if (resultB.isNotEmpty) return resultB;

    return [];
  }

  static Future<List<Map<String, String>>> _tryFetch(Dio dio, String url, String tag) async {
    try {
      final response = await dio.get(url);
      if (response.statusCode == 200) {
        final data = response.data;
        List? pics;
        
        // 暴力解析 JSON 结构
        if (data is Map) {
          if (data['pics'] != null) pics = data['pics'];
          else if (data['data'] is Map && data['data']['pics'] != null) pics = data['data']['pics'];
          else if (data['data'] is Map && data['data']['page_pic'] != null) pics = [data['data']['page_pic']]; // 单图情况
        }

        if (pics == null || pics.isEmpty) {
          // print("⚠️ [$tag] 无图片数据");
          return [];
        }

        List<Map<String, String>> results = [];
        for (var pic in pics) {
          String url = pic['large']?['url'] ?? pic['url']; // 兼容不同字段
          
          String wmUrl = url.replaceAll(RegExp(r'(\/orj360\/|\/oslarge\/|\/mw690\/|\/thumbnail\/|\/bmiddle\/|\/thumb180\/)'), '/large/');
          String origUrl = url.replaceAll(RegExp(r'(\/orj360\/|\/large\/|\/mw690\/|\/thumbnail\/|\/bmiddle\/|\/thumb180\/)'), '/oslarge/');
          
          Uri uri = Uri.parse(url);
          String filename = uri.pathSegments.last.split('.').first;
          String ext = ".${uri.pathSegments.last.split('.').last}";

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
      print("❌ [$tag] Error: $e");
    }
    return [];
  }

  static Future<Map<String, String>?> downloadPair(Map<String, String> item, Function(String) onLog) async {
    Dio dio = Dio();
    dio.options.headers = _baseHeaders; // 下载时只需要基础 Header
    
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
      onLog("❌ 下载失败 (${item['filename']})");
      return null;
    }
  }
}