import 'package:dio/dio.dart';
import 'package:path_provider/path_provider.dart';
import 'dart:io';

class WeiboApi {
  static const Map<String, String> _baseHeaders = {
    'User-Agent': 'Mozilla/5.0 (iPhone; CPU iPhone OS 16_6 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/16.6 Mobile/15E148 Safari/604.1',
    'Accept': 'application/json, text/plain, */*',
    'X-Requested-With': 'XMLHttpRequest',
  };

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

  static String? parseIdFromUrl(String url) {
    // 移动端
    RegExp regStatus = RegExp(r'status(?:es)?\/(\d+)');
    var m1 = regStatus.firstMatch(url);
    if (m1 != null) return m1.group(1);

    RegExp regDetail = RegExp(r'detail\/(\d+)');
    var m2 = regDetail.firstMatch(url);
    if (m2 != null) return m2.group(1);

    RegExp regParam = RegExp(r'weibo_id=(\d+)');
    var m3 = regParam.firstMatch(url);
    if (m3 != null) return m3.group(1);

    // 🆕 PC端增强正则：支持数字或字母的用户ID
    // 格式：weibo.com/用户ID/微博ID
    RegExp regPc = RegExp(r'weibo\.com\/[a-zA-Z0-9]+\/([a-zA-Z0-9]+)');
    var m4 = regPc.firstMatch(url);
    if (m4 != null) return m4.group(1);

    return null;
  }

  /// 🛠️ 链接转换：PC -> Mobile (为了更快加载和获取正确Cookie)
  static String convertToMobileUrl(String url) {
    if (url.contains("weibo.com")) {
      String? id = parseIdFromUrl(url);
      if (id != null) {
        return "https://m.weibo.cn/status/$id";
      }
    }
    return url;
  }

  static Future<List<Map<String, String>>> getImageUrls(String weiboId, {String? cookie}) async {
    Dio dio = Dio();
    Map<String, String> headers = Map.from(_baseHeaders);
    if (cookie != null && cookie.isNotEmpty) headers['Cookie'] = cookie;
    dio.options.headers = headers;

    // 策略 A: 标准接口
    String urlA = "https://m.weibo.cn/statuses/show?id=$weiboId";
    List<Map<String, String>> resA = await _tryFetch(dio, urlA);
    if (resA.isNotEmpty) return resA;

    // 策略 B: 扩展接口
    String urlB = "https://m.weibo.cn/statuses/extend?id=$weiboId";
    List<Map<String, String>> resB = await _tryFetch(dio, urlB);
    if (resB.isNotEmpty) return resB;

    return [];
  }

  static Future<List<Map<String, String>>> _tryFetch(Dio dio, String url) async {
    try {
      final response = await dio.get(url);
      if (response.statusCode == 200) {
        var data = response.data;
        if (data is Map && data.containsKey('data')) data = data['data'];
        return _parseWeiboJson(data);
      }
    } catch (e) {
      // ignore
    }
    return [];
  }

  static List<Map<String, String>> _parseWeiboJson(dynamic data) {
    if (data == null || data is! Map) return [];
    
    List<dynamic> pics = [];
    if (data['pics'] != null) pics = data['pics'];
    else if (data['retweeted_status'] != null && data['retweeted_status']['pics'] != null) pics = data['retweeted_status']['pics'];
    else if (data['page_info'] != null && data['page_info']['page_pic'] != null) pics = [data['page_info']['page_pic']];

    if (pics.isEmpty) return [];

    List<Map<String, String>> results = [];
    for (var pic in pics) {
      String url = "";
      if (pic is Map) {
        url = pic['large']?['url'] ?? pic['url'] ?? "";
      } else if (pic is String) {
        url = pic;
      }
      if (url.isEmpty) continue;

      String wmUrl = url.replaceAll(RegExp(r'(\/orj360\/|\/oslarge\/|\/mw690\/|\/thumbnail\/|\/bmiddle\/|\/thumb180\/|\/wap180\/)'), '/large/');
      String origUrl = url.replaceAll(RegExp(r'(\/orj360\/|\/large\/|\/mw690\/|\/thumbnail\/|\/bmiddle\/|\/thumb180\/|\/wap180\/)'), '/oslarge/');
      
      Uri uri = Uri.parse(url);
      String filename = uri.pathSegments.last.split('.').first;
      String ext = ".${uri.pathSegments.last.split('.').last}";
      if (ext.contains("?")) ext = ext.split("?").first;

      results.add({'wm_url': wmUrl, 'orig_url': origUrl, 'filename': filename, 'ext': ext});
    }
    return results;
  }

  static Future<Map<String, String>?> downloadPair(Map<String, String> item, Function(String) onLog) async {
    Dio dio = Dio();
    dio.options.headers = {
      'User-Agent': _baseHeaders['User-Agent'],
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
      onLog("❌ 下载失败");
      return null;
    }
  }
}