import 'package:dio/dio.dart';
import 'package:path_provider/path_provider.dart';
import 'dart:io';

class WeiboApi {
  // 基础伪装
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
    
    // 兼容没有 http 前缀的文本
    if (text.contains("weibo.cn") || text.contains("t.cn") || text.contains("weibo.com")) {
      String clean = text.replaceAll(RegExp(r'\s+'), '');
      if (!clean.startsWith("http")) return "https://$clean";
      return clean;
    }
    return null;
  }

  /// 🆔 纯正则提取 ID (增强版)
  static String? parseIdFromUrl(String url) {
    // 模式 1: status/123 (移动端)
    RegExp regStatus = RegExp(r'status(?:es)?\/(\d+)');
    var m1 = regStatus.firstMatch(url);
    if (m1 != null) return m1.group(1);

    // 模式 2: detail/123 (旧版移动端)
    RegExp regDetail = RegExp(r'detail\/(\d+)');
    var m2 = regDetail.firstMatch(url);
    if (m2 != null) return m2.group(1);

    // 模式 3: weibo_id=123 (参数型)
    RegExp regParam = RegExp(r'weibo_id=(\d+)');
    var m3 = regParam.firstMatch(url);
    if (m3 != null) return m3.group(1);

    // 👇👇👇【新增】模式 4: weibo.com/uid/status_id (PC端) 👇👇👇
    // 匹配 weibo.com/数字/数字 的结构
    RegExp regPc = RegExp(r'weibo\.com\/\d+\/(\d+)');
    var m4 = regPc.firstMatch(url);
    if (m4 != null) return m4.group(1);

    return null;
  }

  /// 🖼️ 获取图片列表
  static Future<List<Map<String, String>>> getImageUrls(String weiboId, {String? cookie}) async {
    Dio dio = Dio();
    Map<String, String> headers = Map.from(_baseHeaders);
    if (cookie != null && cookie.isNotEmpty) {
      headers['Cookie'] = cookie;
    }
    dio.options.headers = headers;

    // 策略 A: 标准接口
    String urlA = "https://m.weibo.cn/statuses/show?id=$weiboId";
    List<Map<String, String>> resultA = await _tryFetch(dio, urlA, "API-A");
    if (resultA.isNotEmpty) return resultA;

    // 策略 B: 扩展接口
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
        
        if (data is Map) {
          if (data['pics'] != null) pics = data['pics'];
          else if (data['data'] is Map && data['data']['pics'] != null) pics = data['data']['pics'];
          else if (data['data'] is Map && data['data']['page_pic'] != null) pics = [data['data']['page_pic']];
        }

        if (pics == null || pics.isEmpty) return [];

        List<Map<String, String>> results = [];
        for (var pic in pics) {
          String url = pic['large']?['url'] ?? pic['url'];
          
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
    // 防盗链 Header
    dio.options.headers = {
      'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
      'Referer': 'https://weibo.com/',
    };
    
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