import 'package:dio/dio.dart';
import 'package:path_provider/path_provider.dart';
import 'dart:io';

class WeiboApi {
  // 伪装成 Android 手机上的 Chrome 浏览器
  static const Map<String, String> _headers = {
    'User-Agent': 'Mozilla/5.0 (Linux; Android 10; K) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36',
    'Accept': 'text/html,application/xhtml+xml,application/xml;q=0.9,image/webp,image/apng,*/*;q=0.8',
    'Accept-Language': 'zh-CN,zh;q=0.9,en;q=0.8',
    'Connection': 'keep-alive',
    'Upgrade-Insecure-Requests': '1',
  };

  /// 🛠️ 工具：从混合文本中提取 http 链接
  static String? extractUrlFromText(String text) {
    // 匹配 http:// 或 https:// 开始，直到空格或换行结束的字符串
    RegExp regExp = RegExp(r'(https?://[a-zA-Z0-9\.\/\-\_\?\=\&\%\#]+)');
    var match = regExp.firstMatch(text);
    return match?.group(0);
  }

  /// 🕵️ 核心：终极链接追踪 (攻克 JS 跳转和 302 跳转)
  static Future<String?> resolveRedirects(String url) async {
    Dio dio = Dio();
    dio.options.headers = _headers;
    dio.options.followRedirects = false; // ⚠️ 我们手动控制跳转，为了抓取 JS 跳转
    dio.options.validateStatus = (status) => status! < 500;
    dio.options.sendTimeout = const Duration(seconds: 5);
    dio.options.receiveTimeout = const Duration(seconds: 5);

    String currentUrl = url;
    int maxSteps = 8; // 最大追踪深度

    print("🔗 [开始追踪] $currentUrl");

    for (int i = 0; i < maxSteps; i++) {
      // 🎯 1. 检查是否已经是终点链接 (包含 status 或 detail)
      if (currentUrl.contains("m.weibo.cn/status") || 
          currentUrl.contains("weibo.cn/detail") ||
          currentUrl.contains("/status/") // 兼容 PC 端链接
         ) {
        print("✅ [追踪成功] 锁定终点: $currentUrl");
        return currentUrl;
      }

      try {
        Response response = await dio.get(currentUrl);

        // 🎯 2. 处理 HTTP 3xx 跳转
        if (response.statusCode == 301 || response.statusCode == 302 || response.statusCode == 307) {
          String? location = response.headers.value('location');
          if (location != null && location.isNotEmpty) {
            // 处理相对路径
            if (location.startsWith("/")) {
               Uri u = Uri.parse(currentUrl);
               currentUrl = "${u.scheme}://${u.host}$location";
            } else {
               currentUrl = location;
            }
            print("👉 [HTTP跳转] -> $currentUrl");
            continue;
          }
        }

        // 🎯 3. 处理 HTML JS 跳转 (Weibo 最爱用的招数)
        // 它们会返回 200 OK，但在 body 里写 window.location.href
        if (response.statusCode == 200) {
          String body = response.data.toString();
          
          // 匹配 window.location.href = "..."
          // 或者 window.location.replace("...")
          RegExp jsRedirect = RegExp(r'location\.(?:href|replace)\s*[\(=]\s*["\x27]([^"\x27]+)["\x27]');
          var match = jsRedirect.firstMatch(body);
          
          if (match != null) {
            String newUrl = match.group(1)!;
            // 很多时候是 'https://m.weibo.cn/status/...' 
            currentUrl = newUrl;
            print("👉 [JS伪装跳转] -> $currentUrl");
            continue;
          } else {
            // 如果 200 OK 且没有 JS 跳转，可能这里就是终点，或者这是一个无需登录的页面
            // 尝试直接返回当前 URL 碰碰运气
            return currentUrl;
          }
        }
      } catch (e) {
        print("⚠️ 追踪中断: $e");
        break;
      }
    }
    return null; // 追踪失败
  }

  /// 🆔 提取 ID
  static Future<String?> getWeiboId(String rawText) async {
    // 1. 先从乱七八糟的复制文本中提取出 URL
    String? cleanUrl = extractUrlFromText(rawText);
    if (cleanUrl == null) {
      print("❌ 未在文本中发现 URL");
      return null;
    }

    // 2. 追踪最终 URL
    String? finalUrl = await resolveRedirects(cleanUrl);
    if (finalUrl == null) return null;

    // 3. 正则提取 ID (增加多种匹配模式)
    
    // 模式 A: m.weibo.cn/status/49832...
    RegExp regStatus = RegExp(r'status(?:es)?\/(\d+)');
    var m1 = regStatus.firstMatch(finalUrl);
    if (m1 != null) return m1.group(1);

    // 模式 B: m.weibo.cn/detail/49832...
    RegExp regDetail = RegExp(r'detail\/(\d+)');
    var m2 = regDetail.firstMatch(finalUrl);
    if (m2 != null) return m2.group(1);

    // 模式 C: weibo.com/12345/N5... (PC端 Base62 ID)
    // 注意：微博 API 有时不支持 Base62 ID，通常需要转为数字 ID。
    // 但 m.weibo.cn/statuses/show 接口通常比较智能，支持混合。
    // 如果这里提取的是 N5xxx，后续 API 请求可能会失败，但这是最后的尝试。
    RegExp regPc = RegExp(r'weibo\.com\/\d+\/([a-zA-Z0-9]+)');
    var m3 = regPc.firstMatch(finalUrl);
    if (m3 != null) return m3.group(1);

    return null;
  }

  /// 🖼️ 获取图片
  static Future<List<Map<String, String>>> getImageUrls(String weiboId) async {
    final url = "https://m.weibo.cn/statuses/show?id=$weiboId";
    Dio dio = Dio();
    // 必须带 Header，否则会被判定为爬虫返回 403
    dio.options.headers = _headers; 
    
    try {
      print("📡 请求微博API: $url");
      final response = await dio.get(url);
      
      if (response.statusCode == 200) {
        final data = response.data;
        // 检查数据结构
        if (data == null || data['ok'] != 1) {
          print("⚠️ API返回错误: $data");
          return [];
        }

        final pics = data['data']?['pics'] as List?;
        if (pics == null) return [];

        List<Map<String, String>> results = [];
        for (var pic in pics) {
          String url = pic['large']['url'];
          
          // 强制替换为最高清的 livephoto 或者 large 链接
          // 微博图床规则复杂，尝试替换所有可能的低清前缀
          String wmUrl = url.replaceAll(RegExp(r'(\/orj360\/|\/oslarge\/|\/mw690\/|\/thumbnail\/|\/bmiddle\/)'), '/large/');
          String origUrl = url.replaceAll(RegExp(r'(\/orj360\/|\/large\/|\/mw690\/|\/thumbnail\/|\/bmiddle\/)'), '/oslarge/');
          
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
    dio.options.headers = _headers; // 下载也带上 header 防止防盗链
    
    Directory tempDir = await getTemporaryDirectory();
    String baseName = item['filename']!;
    String ext = item['ext']!;
    String wmPath = "${tempDir.path}/$baseName-wm$ext";
    String origPath = "${tempDir.path}/$baseName-orig$ext";

    try {
      await dio.download(item['wm_url']!, wmPath);
      await dio.download(item['orig_url']!, origPath);
      return {'wm': wmPath, 'clean': origPath};
    } catch (e) {
      onLog("❌ 下载失败 (${item['filename']}): ${e.toString()}");
      return null;
    }
  }
}