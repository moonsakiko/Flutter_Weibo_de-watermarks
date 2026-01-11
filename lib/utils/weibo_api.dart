import 'package:dio/dio.dart';
import 'package:path_provider/path_provider.dart';
import 'dart:io';

class WeiboApi {
  static const Map<String, String> _headers = {
    'User-Agent': 'Mozilla/5.0 (iPhone; CPU iPhone OS 13_2_3 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/13.0.3 Mobile/15E148 Safari/604.1',
  };

  /// 🛠️ 宽容的链接提取 (支持不带http的文本)
  static String? extractUrlFromText(String text) {
    // 1. 尝试匹配标准链接
    RegExp regExp = RegExp(r'(https?://[a-zA-Z0-9\.\/\-\_\?\=\&\%\#]+)');
    var match = regExp.firstMatch(text);
    if (match != null) return match.group(0);

    // 2. 如果没匹配到，且文本包含 weibo.cn 或 t.cn，尝试手动补全
    if (text.contains("weibo.cn") || text.contains("t.cn") || text.contains("weibo.com")) {
      // 去除空格回车
      String clean = text.replaceAll(RegExp(r'\s+'), '');
      if (!clean.startsWith("http")) {
        return "https://$clean";
      }
      return clean;
    }
    
    return null;
  }

  /// 🆔 纯正则提取 ID (不发网络请求)
  static String? parseIdFromUrl(String url) {
    // 模式 1: status/123
    RegExp regStatus = RegExp(r'status(?:es)?\/(\d+)');
    var m1 = regStatus.firstMatch(url);
    if (m1 != null) return m1.group(1);

    // 模式 2: detail/123
    RegExp regDetail = RegExp(r'detail\/(\d+)');
    var m2 = regDetail.firstMatch(url);
    if (m2 != null) return m2.group(1);

    // 模式 3: weibo_id=123
    RegExp regParam = RegExp(r'weibo_id=(\d+)');
    var m3 = regParam.firstMatch(url);
    if (m3 != null) return m3.group(1);

    return null;
  }

  /// 🖼️ 获取图片列表
  static Future<List<Map<String, String>>> getImageUrls(String weiboId) async {
    final url = "https://m.weibo.cn/statuses/show?id=$weiboId";
    Dio dio = Dio();
    dio.options.headers = _headers; 
    
    try {
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
          
          // 修复文件名提取逻辑，防止 url 带参数导致文件名错误
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
      print("API Error: $e");
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
      onLog("❌ 下载失败 (${item['filename']})");
      return null;
    }
  }
}