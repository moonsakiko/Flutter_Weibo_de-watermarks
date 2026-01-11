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
    // 兼容不带 http 的 weibo.com
    if (text.contains("weibo.cn") || text.contains("t.cn") || text.contains("weibo.com")) {
      String clean = text.replaceAll(RegExp(r'\s+'), '');
      if (!clean.startsWith("http")) return "https://$clean";
      return clean;
    }
    return null;
  }

  /// 🆔 纯正则提取 ID (已增强支持 PC 链接)
  static String? parseIdFromUrl(String url) {
    // 模式 1: m.weibo.cn/status/123456
    RegExp regStatus = RegExp(r'status(?:es)?\/(\d+)');
    var m1 = regStatus.firstMatch(url);
    if (m1 != null) return m1.group(1);

    // 模式 2: m.weibo.cn/detail/123456
    RegExp regDetail = RegExp(r'detail\/(\d+)');
    var m2 = regDetail.firstMatch(url);
    if (m2 != null) return m2.group(1);

    // 模式 3: weibo_id=123456
    RegExp regParam = RegExp(r'weibo_id=(\d+)');
    var m3 = regParam.firstMatch(url);
    if (m3 != null) return m3.group(1);

    // 🆕 模式 4: PC 端链接 https://weibo.com/12345/N5xxx 或 /5252xxx
    // 匹配 weibo.com/数字/字母或数字
    if (url.contains("weibo.com")) {
      RegExp regPC = RegExp(r'weibo\.com\/\d+\/([a-zA-Z0-9]+)');
      var m4 = regPC.firstMatch(url);
      if (m4 != null) return m4.group(1);
    }

    return null;
  }

  /// 🖼️ 获取图片列表 (支持 Cookie 注入 + 双接口备选)
  static Future<List<Map<String, String>>> getImageUrls(String weiboId, {String? cookie}) async {
    Dio dio = Dio();
    Map<String, String> headers = Map.from(_baseHeaders);
    if (cookie != null && cookie.isNotEmpty) {
      headers['Cookie'] = cookie;
    }
    dio.options.headers = headers;

    // 策略 A: 移动端标准接口 (仅限纯数字 ID)
    if (RegExp(r'^\d+$').hasMatch(weiboId)) {
      String urlA = "https://m.weibo.cn/statuses/show?id=$weiboId";
      List<Map<String, String>> resultA = await _tryFetch(dio, urlA, "API-A");
      if (resultA.isNotEmpty) return resultA;

      String urlB = "https://m.weibo.cn/statuses/extend?id=$weiboId";
      List<Map<String, String>> resultB = await _tryFetch(dio, urlB, "API-B");
      if (resultB.isNotEmpty) return resultB;
    }

    // 策略 C: PC端接口 (支持 Base62 ID 和 数字 ID，通用性最强)
    // 您的那个链接 weibo.com/.../5252... 将会主要通过这个策略解析
    String urlC = "https://weibo.com/ajax/statuses/show?id=$weiboId";
    // PC 接口需要 PC User-Agent
    dio.options.headers = {
      'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
      'Cookie': cookie ?? '',
      'Referer': 'https://weibo.com/',
    };
    List<Map<String, String>> resultC = await _tryFetch(dio, urlC, "API-C");
    if (resultC.isNotEmpty) return resultC;

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
          else if (data['pic_infos'] != null) { 
             // PC 端 ajax 接口返回的是 pic_infos (Map)，需要转 List
             pics = (data['pic_infos'] as Map).values.toList();
          }
          // 检查转发
          else if (data['retweeted_status'] != null) {
             var retweet = data['retweeted_status'];
             if (retweet['pics'] != null) pics = retweet['pics'];
             else if (retweet['pic_infos'] != null) pics = (retweet['pic_infos'] as Map).values.toList();
          }
        }

        if (pics == null || pics.isEmpty) return [];

        List<Map<String, String>> results = [];
        for (var pic in pics) {
          String url = "";
          // 兼容 Mobile 和 PC 接口不同的字段
          if (pic is Map) {
            if (pic.containsKey('large')) url = pic['large']['url']; // Mobile
            else if (pic.containsKey('largest')) url = pic['largest']['url']; // PC
            else if (pic.containsKey('mw2000')) url = pic['mw2000']['url']; // PC
            else if (pic.containsKey('url')) url = pic['url'];
          } else if (pic is String) {
            url = pic;
          }

          if (url.isEmpty) continue;

          // 统一替换为高清
          String wmUrl = url.replaceAll(RegExp(r'(\/orj360\/|\/oslarge\/|\/mw690\/|\/thumbnail\/|\/bmiddle\/|\/thumb180\/|\/wap180\/)'), '/large/');
          String origUrl = url.replaceAll(RegExp(r'(\/orj360\/|\/large\/|\/mw690\/|\/thumbnail\/|\/bmiddle\/|\/thumb180\/|\/wap180\/)'), '/oslarge/');
          
          Uri uri = Uri.parse(url);
          String filename = uri.pathSegments.last.split('.').first;
          String ext = ".${uri.pathSegments.last.split('.').last}";
          if (ext.contains("?")) ext = ext.split("?").first;

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