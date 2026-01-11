import 'package:dio/dio.dart';
import 'package:path_provider/path_provider.dart';
import 'dart:io';

class WeiboApi {
  // 伪装成安卓微博客户端或浏览器
  static const Map<String, String> _headers = {
    'User-Agent': 'Mozilla/5.0 (Linux; Android 10; K) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/114.0.0.0 Mobile Safari/537.36',
    'Accept': 'text/html,application/xhtml+xml,application/xml;q=0.9,image/webp,*/*;q=0.8',
  };

  /// 🕵️ 强力链接追踪
  static Future<String?> resolveRedirects(String url) async {
    Dio dio = Dio();
    dio.options.headers = _headers;
    dio.options.followRedirects = true;
    dio.options.validateStatus = (status) => status! < 500;
    
    try {
      // 1. 尝试直接 HEAD 请求获取最终地址
      Response response = await dio.head(url);
      String realUrl = response.realUri.toString();
      
      // 2. 如果 HEAD 没拿到，尝试 GET
      if (realUrl == url) {
         response = await dio.get(url);
         realUrl = response.realUri.toString();
      }
      return realUrl;
    } catch (e) {
      print("Link Resolve Error: $e");
      return url; // 解析失败则返回原链接碰碰运气
    }
  }

  static Future<String?> getWeiboId(String link) async {
    String finalLink = link;
    
    // 只要不是标准链接，就去追踪
    if (!link.contains("m.weibo.cn/status")) {
      final resolved = await resolveRedirects(link);
      if (resolved != null) finalLink = resolved;
    }

    // 正则提取
    RegExp regExp1 = RegExp(r'status(?:es)?\/(\d+)');
    var match1 = regExp1.firstMatch(finalLink);
    if (match1 != null) return match1.group(1);

    RegExp regExp2 = RegExp(r'weibo_id=(\d+)');
    var match2 = regExp2.firstMatch(finalLink);
    if (match2 != null) return match2.group(1);

    return null;
  }

  static Future<List<Map<String, String>>> getImageUrls(String weiboId) async {
    // 使用 m.weibo.cn 的 API
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
          // 替换高清规则
          String wmUrl = url.replaceAll(RegExp(r'(\/orj360\/|\/oslarge\/|\/mw690\/)'), '/large/');
          String origUrl = url.replaceAll(RegExp(r'(\/orj360\/|\/large\/|\/mw690\/)'), '/oslarge/');
          
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