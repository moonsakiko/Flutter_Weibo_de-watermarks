import 'dart:convert';
import 'package:dio/dio.dart';
import 'package:path_provider/path_provider.dart';
import 'dart:io';

class WeiboApi {
  static const Map<String, String> _headers = {
    'User-Agent': 'Mozilla/5.0 (iPhone; CPU iPhone OS 13_2_3 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/13.0.3 Mobile/15E148 Safari/604.1',
    'Referer': 'https://m.weibo.cn/',
    'Accept': 'application/json, text/plain, */*',
  };

  /// 🆕 核心升级：解析重定向链接
  static Future<String?> resolveRedirects(String url) async {
    Dio dio = Dio();
    // 禁止自动重定向，我们需要手动捕获 location 或者让 dio 自动走完拿到 final path
    // 这里我们利用 dio 默认会跟随重定向的特性，直接取 response.realUri
    try {
      Response response = await dio.get(
        url,
        options: Options(
          headers: _headers,
          followRedirects: true,
          validateStatus: (status) => status! < 500, // 允许所有状态码以免报错
        ),
      );
      // 获取最终跳转后的 URL
      return response.realUri.toString();
    } catch (e) {
      print("链接解析错误: $e");
      return null;
    }
  }

  /// 1. 从链接提取 ID (增强版)
  static Future<String?> getWeiboId(String link) async {
    String? finalLink = link;

    // 如果是短链或者 mapp 开头的，先解析出真实链接
    if (link.contains('t.cn') || link.contains('mapp.api.weibo.cn') || link.contains('share.api.weibo.cn')) {
      finalLink = await resolveRedirects(link);
      if (finalLink == null) return null;
      print("🔗 追踪到真实链接: $finalLink");
    }

    // 匹配 weibo.cn/status/123456...
    RegExp regExp1 = RegExp(r'status(?:es)?\/(\d+)');
    var match1 = regExp1.firstMatch(finalLink!);
    if (match1 != null) return match1.group(1);

    // 匹配 weibo_id=123456...
    RegExp regExp2 = RegExp(r'weibo_id=(\d+)');
    var match2 = regExp2.firstMatch(finalLink);
    if (match2 != null) return match2.group(1);
    
    // 匹配 /fx/xxxx 这种非常规哈希 (通常 mapp 链接解析后会变成 status 链接，如果还是不行则无法处理)
    return null; 
  }

  /// 2. 获取图片列表 (高清+原图)
  static Future<List<Map<String, String>>> getImageUrls(String weiboId) async {
    final url = "https://m.weibo.cn/statuses/show?id=$weiboId";
    Dio dio = Dio();
    try {
      final response = await dio.get(url, options: Options(headers: _headers));
      if (response.statusCode == 200) {
        final data = response.data; // Dio 自动解析 JSON
        final pics = data['data']?['pics'] as List?;
        if (pics == null) return [];

        List<Map<String, String>> results = [];
        for (var pic in pics) {
          String url = pic['large']['url'];
          
          // 构造下载链接
          String wmUrl = url.replaceAll(RegExp(r'(\/orj360\/|\/oslarge\/)'), '/large/');
          String origUrl = url.replaceAll(RegExp(r'(\/orj360\/|\/large\/)'), '/oslarge/');
          
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

  /// 3. 下载并保存
  static Future<Map<String, String>?> downloadPair(Map<String, String> item, Function(String) onStatus) async {
    Dio dio = Dio();
    Directory tempDir = await getTemporaryDirectory();
    String baseName = item['filename']!;
    String ext = item['ext']!;

    String wmPath = "${tempDir.path}/$baseName-wm$ext";
    String origPath = "${tempDir.path}/$baseName-orig$ext";

    try {
      // 检查文件是否存在，避免重复下载
      if (!File(wmPath).existsSync()) {
        await dio.download(item['wm_url']!, wmPath);
      }
      if (!File(origPath).existsSync()) {
        await dio.download(item['orig_url']!, origPath);
      }
      
      return {'wm': wmPath, 'clean': origPath};
    } catch (e) {
      onStatus("❌ 下载失败: $baseName");
      return null;
    }
  }
}