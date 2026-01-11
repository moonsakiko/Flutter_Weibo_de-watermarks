import 'package:dio/dio.dart';
import 'package:path_provider/path_provider.dart';
import 'dart:io';

class WeiboApi {
  // 方案 A: Auto.js 同款请求头 (伪装成 iPhone) - 成功率最高
  static const Map<String, String> _headers_ios = {
    'User-Agent': 'Mozilla/5.0 (iPhone; CPU iPhone OS 13_2_3 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/13.0.3 Mobile/15E148 Safari/604.1',
    'Referer': 'https://m.weibo.cn/',
    'Accept': 'application/json, text/plain, */*',
    'X-Requested-With': 'XMLHttpRequest',
  };

  // 方案 B: 电脑端请求头 (伪装成 PC) - 用于对抗某些手机端强跳 APP 的情况
  static const Map<String, String> _headers_pc = {
    'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
    'Accept': 'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
  };

  /// 🛠️ 工具：从混合文本中提取 http 链接
  static String? extractUrlFromText(String text) {
    RegExp regExp = RegExp(r'(https?://[a-zA-Z0-9\.\/\-\_\?\=\&\%\#]+)');
    var match = regExp.firstMatch(text);
    return match?.group(0);
  }

  /// 🕵️ 核心：多重策略解析 ID
  static Future<String?> getWeiboId(String rawText) async {
    // 1. 提取 URL
    String? url = extractUrlFromText(rawText);
    if (url == null) return null;

    print("🔍 [解析开始] 原始链接: $url");

    // 2. 尝试策略 A (iOS 伪装) - 模仿 Auto.js
    String? id = await _tryResolveId(url, _headers_ios, "策略A(iOS)");
    if (id != null) return id;

    // 3. 尝试策略 B (PC 伪装)
    id = await _tryResolveId(url, _headers_pc, "策略B(PC)");
    if (id != null) return id;

    return null;
  }

  /// 内部方法：尝试解析
  static Future<String?> _tryResolveId(String url, Map<String, String> headers, String strategyName) async {
    Dio dio = Dio();
    dio.options.headers = headers;
    dio.options.followRedirects = true; // 让 Dio 自动跟进 302 跳转
    dio.options.validateStatus = (status) => status! < 500;
    dio.options.receiveTimeout = const Duration(seconds: 5);
    dio.options.sendTimeout = const Duration(seconds: 5);

    try {
      // 发起请求
      Response response = await dio.get(url);
      
      // 1. 检查最终 URL (Dio 会自动更新 realUri)
      String finalUrl = response.realUri.toString();
      String? id = _extractIdFromUrl(finalUrl);
      if (id != null) {
        print("✅ [$strategyName] 通过 URL 解析成功: $id");
        return id;
      }

      // 2. 检查 Response Body (应对 200 OK 但包含 JS 跳转的情况)
      if (response.statusCode == 200) {
        String body = response.data.toString();
        
        // 匹配 HTML 中的 window.location.href = '...'
        // 常见于 mapp.api.weibo.cn 的中间页
        RegExp jsRedirect = RegExp(r'["\x27]((?:https?:)?\\?/\\?/m\.weibo\.cn\\?/status\\?/\d+)["\x27]');
        var match = jsRedirect.firstMatch(body);
        if (match != null) {
          String newUrl = match.group(1)!.replaceAll('\\', ''); // 去除转义符
          print("👉 [$strategyName] 发现 JS 跳转: $newUrl");
          return _extractIdFromUrl(newUrl);
        }

        // 匹配 render_data 中的 id (某些 PC 页面)
        RegExp renderData = RegExp(r'"status_id":\s*"(\d+)"');
        var match2 = renderData.firstMatch(body);
        if (match2 != null) return match2.group(1);
      }
      
    } catch (e) {
      print("⚠️ [$strategyName] 失败: $e");
    }
    return null;
  }

  /// 纯正则提取 ID
  static String? _extractIdFromUrl(String url) {
    // 模式 1: m.weibo.cn/status/49832...
    RegExp regStatus = RegExp(r'status(?:es)?\/(\d+)');
    var m1 = regStatus.firstMatch(url);
    if (m1 != null) return m1.group(1);

    // 模式 2: weibo.cn/detail/49832...
    RegExp regDetail = RegExp(r'detail\/(\d+)');
    var m2 = regDetail.firstMatch(url);
    if (m2 != null) return m2.group(1);

    // 模式 3: 参数 weibo_id=123
    RegExp regParam = RegExp(r'weibo_id=(\d+)');
    var m3 = regParam.firstMatch(url);
    if (m3 != null) return m3.group(1);

    return null;
  }

  /// 🖼️ 获取图片 (保持不变，这部分是通用的)
  static Future<List<Map<String, String>>> getImageUrls(String weiboId) async {
    final url = "https://m.weibo.cn/statuses/show?id=$weiboId";
    Dio dio = Dio();
    // 使用 iOS Header 获取数据，通常最稳
    dio.options.headers = _headers_ios; 
    
    try {
      print("📡 请求微博API: $url");
      final response = await dio.get(url);
      
      if (response.statusCode == 200) {
        final data = response.data;
        // 容错处理
        if (data == null) return [];
        
        // 有些返回结构是 data -> pics，有些是 data -> data -> pics
        List? pics;
        if (data['pics'] != null) {
             pics = data['pics'];
        } else if (data['data'] != null && data['data'] is Map && data['data']['pics'] != null) {
             pics = data['data']['pics'];
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
    dio.options.headers = _headers_ios; 
    
    Directory tempDir = await getTemporaryDirectory();
    String baseName = item['filename']!;
    String ext = item['ext']!;
    String wmPath = "${tempDir.path}/$baseName-wm$ext";
    String origPath = "${tempDir.path}/$baseName-orig$ext";

    try {
      // 并行下载，提高速度
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