import 'package:dio/dio.dart';
import 'package:path_provider/path_provider.dart';
import 'dart:io';

class WeiboApi {
  // 伪装成 Chrome 浏览器，而不是安卓客户端，这通常能获得更标准的重定向行为
  static const Map<String, String> _headers = {
    'User-Agent': 'Mozilla/5.0 (Linux; Android 10; K) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/114.0.0.0 Mobile Safari/537.36',
    'Accept': 'text/html,application/xhtml+xml,application/xml;q=0.9,image/webp,*/*;q=0.8',
    'Upgrade-Insecure-Requests': '1',
  };

  /// 🕵️ 终极链接追踪
  static Future<String?> resolveRedirects(String url) async {
    Dio dio = Dio();
    // 允许 3xx 状态码不报错
    dio.options.validateStatus = (status) => status! < 500;
    dio.options.followRedirects = false; // 我们手动处理重定向
    dio.options.headers = _headers;

    String currentUrl = url;
    int maxRedirects = 5; // 防止死循环

    try {
      for (int i = 0; i < maxRedirects; i++) {
        // 如果已经是标准 ID 链接，直接返回
        if (currentUrl.contains("m.weibo.cn/status") || currentUrl.contains("weibo.cn/detail")) {
          return currentUrl;
        }

        Response response = await dio.get(currentUrl);
        
        // 检查 3xx 跳转
        if (response.statusCode == 301 || response.statusCode == 302 || response.statusCode == 307) {
          String? location = response.headers.value('location');
          if (location != null && location.isNotEmpty) {
            currentUrl = location;
            // 处理相对路径跳转
            if (currentUrl.startsWith("/")) {
               Uri uri = Uri.parse(url);
               currentUrl = "${uri.scheme}://${uri.host}$currentUrl";
            }
            continue; 
          }
        }
        
        // 某些 js 跳转或者 meta 刷新，直接返回最终 URL (Dio 会自动更新 realUri 如果开启 followRedirects, 但我们手动控制更稳)
        // 如果这里返回的是 200，说明已经到达终点
        if (response.statusCode == 200) {
           // 有时候 mapp 会返回一个包含 script 的 html 来跳转，这里简单处理一下
           // 如果内容包含 window.location.href，尝试提取（高级功能暂略，通常 header location 够用了）
           return currentUrl;
        }
        break;
      }
    } catch (e) {
      print("Link Resolve Error: $e");
    }
    return currentUrl;
  }

  static Future<String?> getWeiboId(String link) async {
    String finalLink = link;
    
    // 只要不是标准链接，就去追踪
    if (!link.contains("m.weibo.cn/status") && !link.contains("weibo.cn/detail")) {
      final resolved = await resolveRedirects(link);
      if (resolved != null) finalLink = resolved;
    }

    // 正则提取 1: m.weibo.cn/status/4988...
    RegExp regExp1 = RegExp(r'status(?:es)?\/(\d+)');
    var match1 = regExp1.firstMatch(finalLink);
    if (match1 != null) return match1.group(1);

    // 正则提取 2: weibo.cn/detail/4988...
    RegExp regExp2 = RegExp(r'detail\/(\d+)');
    var match2 = regExp2.firstMatch(finalLink);
    if (match2 != null) return match2.group(1);

    // 正则提取 3: weibo_id=4988...
    RegExp regExp3 = RegExp(r'weibo_id=(\d+)');
    var match3 = regExp3.firstMatch(finalLink);
    if (match3 != null) return match3.group(1);

    return null;
  }

  static Future<List<Map<String, String>>> getImageUrls(String weiboId) async {
    final url = "https://m.weibo.cn/statuses/show?id=$weiboId";
    Dio dio = Dio();
    try {
      final response = await dio.get(url, options: Options(headers: _headers));
      if (response.statusCode == 200) {
        final data = response.data;
        final pics = data['data']?['pics'] as List?;
        if (pics == null) return [];

        List<Map<String, String>> results = [];
        for (var pic in pics) {
          String url = pic['large']['url'];
          String wmUrl = url.replaceAll(RegExp(r'(\/orj360\/|\/oslarge\/|\/mw690\/|\/thumbnail\/)'), '/large/');
          String origUrl = url.replaceAll(RegExp(r'(\/orj360\/|\/large\/|\/mw690\/|\/thumbnail\/)'), '/oslarge/');
          
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
      print("API Error: $e");
    }
    return [];
  }

  static Future<Map<String, String>?> downloadPair(Map<String, String> item, Function(String) onLog) async {
    Dio dio = Dio();
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
      onLog("❌ 下载失败: ${e.toString()}");
      return null;
    }
  }
}