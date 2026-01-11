import 'package:dio/dio.dart';
import 'package:path_provider/path_provider.dart';
import 'dart:io';

class WeiboApi {
  // 移动端伪装
  static const Map<String, String> _headersMobile = {
    'User-Agent': 'Mozilla/5.0 (iPhone; CPU iPhone OS 16_6 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/16.6 Mobile/15E148 Safari/604.1',
    'Accept': 'application/json, text/plain, */*',
    'MWeibo-Pwa': '1',
    'Referer': 'https://m.weibo.cn/',
    'X-Requested-With': 'XMLHttpRequest',
  };

  // PC端伪装
  static const Map<String, String> _headersPC = {
    'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
    'Accept': 'application/json, text/plain, */*',
    'Referer': 'https://weibo.com/',
  };

  static String? extractUrlFromText(String text) {
    // 1. 标准 HTTP 提取
    RegExp regExp = RegExp(r'(https?://[a-zA-Z0-9\.\/\-\_\?\=\&\%\#]+)');
    var match = regExp.firstMatch(text);
    if (match != null) return match.group(0);

    // 2. 补全提取 (兼容不带 http 的 weibo.com)
    if (text.contains("weibo.cn") || text.contains("t.cn") || text.contains("weibo.com")) {
      String clean = text.replaceAll(RegExp(r'\s+'), ''); // 去除空格
      // 简单清理一下可能的中文前缀
      int start = clean.indexOf("weibo");
      if (start == -1) start = clean.indexOf("t.cn");
      
      if (start != -1) {
        clean = clean.substring(start);
        return "https://$clean";
      }
    }
    return null;
  }

  static String? parseIdFromUrl(String url) {
    // 模式 1: 移动端 status (m.weibo.cn/status/123456)
    RegExp regStatus = RegExp(r'status(?:es)?\/(\d+)');
    var m1 = regStatus.firstMatch(url);
    if (m1 != null) return m1.group(1);

    // 模式 2: 移动端 detail (weibo.cn/detail/123456)
    RegExp regDetail = RegExp(r'detail\/(\d+)');
    var m2 = regDetail.firstMatch(url);
    if (m2 != null) return m2.group(1);

    // 模式 3: 参数提取 (weibo_id=123456)
    RegExp regParam = RegExp(r'weibo_id=(\d+)');
    var m3 = regParam.firstMatch(url);
    if (m3 != null) return m3.group(1);

    // 👇👇👇【新增】模式 4: PC 端直链 (weibo.com/uid/mid) 👇👇👇
    // 匹配形如 https://weibo.com/7988252585/5252652658066818
    // 其中第二组数字就是我们需要的 ID
    RegExp regPc = RegExp(r'weibo\.com\/\d+\/(\d+)');
    var m4 = regPc.firstMatch(url);
    if (m4 != null) return m4.group(1);

    return null;
  }

  static Future<List<Map<String, String>>> getImageUrls(String weiboId, {String? cookie}) async {
    Dio dio = Dio();
    
    // 策略 A: 移动端标准
    List<Map<String, String>> resA = await _fetchMobile(dio, weiboId, cookie);
    if (resA.isNotEmpty) return resA;

    // 策略 B: 移动端扩展 (针对长文)
    List<Map<String, String>> resB = await _fetchMobile(dio, weiboId, cookie, isExtend: true);
    if (resB.isNotEmpty) return resB;

    // 策略 C: PC端接口 (兜底)
    List<Map<String, String>> resC = await _fetchPC(dio, weiboId, cookie);
    if (resC.isNotEmpty) return resC;

    return [];
  }

  static Future<List<Map<String, String>>> _fetchMobile(Dio dio, String id, String? cookie, {bool isExtend = false}) async {
    String url = isExtend 
        ? "https://m.weibo.cn/statuses/extend?id=$id"
        : "https://m.weibo.cn/statuses/show?id=$id";
    
    Map<String, String> headers = Map.from(_headersMobile);
    if (cookie != null) headers['Cookie'] = cookie;
    dio.options.headers = headers;

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

  static Future<List<Map<String, String>>> _fetchPC(Dio dio, String id, String? cookie) async {
    // 尝试使用 PC 端 Ajax 接口，它对长数字 ID 支持很好
    String url = "https://weibo.com/ajax/statuses/show?id=$id";
    Map<String, String> headers = Map.from(_headersPC);
    if (cookie != null) headers['Cookie'] = cookie;
    dio.options.headers = headers;

    try {
      final response = await dio.get(url);
      if (response.statusCode == 200) return _parseWeiboJson(response.data);
    } catch (e) {
      // ignore
    }
    return [];
  }

  static List<Map<String, String>> _parseWeiboJson(dynamic data) {
    if (data == null || data is! Map) return [];
    
    List<dynamic> pics = [];
    if (data['pics'] != null) {
      pics = data['pics'];
    } else if (data['retweeted_status'] != null && data['retweeted_status']['pics'] != null) {
      pics = data['retweeted_status']['pics'];
    } else if (data['page_info'] != null && data['page_info']['page_pic'] != null) {
      pics = [data['page_info']['page_pic']];
    }

    if (pics.isEmpty) return [];

    List<Map<String, String>> results = [];
    for (var pic in pics) {
      String url = "";
      if (pic is Map) {
        if (pic.containsKey('large')) url = pic['large']['url'];
        else if (pic.containsKey('url')) url = pic['url'];
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
    // 保持原来的防盗链破解逻辑
    dio.options.headers = {
      'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
      'Referer': 'https://weibo.com/',
      'Accept': 'image/avif,image/webp,image/apng,image/svg+xml,image/*,*/*;q=0.8',
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