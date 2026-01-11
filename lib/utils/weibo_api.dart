import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;
import 'package:dio/dio.dart';
import 'package:path_provider/path_provider.dart';

class WeiboApi {
  static const Map<String, String> _headers = {
    'User-Agent': 'Mozilla/5.0 (iPhone; CPU iPhone OS 13_2_3 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/13.0.3 Mobile/15E148 Safari/604.1',
    'Referer': 'https://m.weibo.cn/',
    'Accept': 'application/json, text/plain, */*',
    'X-Requested-With': 'XMLHttpRequest'
  };

  /// 1. 从链接提取 ID
  static String? getWeiboId(String link) {
    // 匹配 weibo.cn/status/123456...
    RegExp regExp1 = RegExp(r'status(?:es)?\/(\d+)');
    var match1 = regExp1.firstMatch(link);
    if (match1 != null) return match1.group(1);

    // 匹配 weibo_id=123456...
    RegExp regExp2 = RegExp(r'weibo_id=(\d+)');
    var match2 = regExp2.firstMatch(link);
    if (match2 != null) return match2.group(1);

    return null; // 如果是短链，可能需要先发请求获取重定向后的URL，这里暂略
  }

  /// 2. 获取图片列表 (高清+原图)
  static Future<List<Map<String, String>>> getImageUrls(String weiboId) async {
    final url = Uri.parse("https://m.weibo.cn/statuses/show?id=$weiboId");
    try {
      final response = await http.get(url, headers: _headers);
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        final pics = data['data']?['pics'] as List?;
        if (pics == null) return [];

        List<Map<String, String>> results = [];
        for (var pic in pics) {
          String url = pic['large']['url'];
          // 构造下载链接
          String wmUrl = url.replaceAll(RegExp(r'(\/orj360\/|\/oslarge\/)'), '/large/');
          String origUrl = url.replaceAll(RegExp(r'(\/orj360\/|\/large\/)'), '/oslarge/');
          
          // 提取文件名
          String filename = url.split('/').last.split('?').first.split('.').first;
          String ext = "." + (url.split('.').last.split('?').first); // .jpg

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

  /// 3. 下载并保存到临时目录，返回本地路径对
  static Future<Map<String, String>?> downloadPair(Map<String, String> item, Function(String) onStatus) async {
    Dio dio = Dio();
    Directory tempDir = await getTemporaryDirectory();
    String baseName = item['filename']!;
    String ext = item['ext']!;

    String wmPath = "${tempDir.path}/$baseName-wm$ext";
    String origPath = "${tempDir.path}/$baseName-orig$ext";

    try {
      onStatus("⬇️ 下载水印图...");
      await dio.download(item['wm_url']!, wmPath);
      
      onStatus("⬇️ 下载原图...");
      await dio.download(item['orig_url']!, origPath);
      
      return {'wm': wmPath, 'clean': origPath};
    } catch (e) {
      onStatus("❌ 下载失败: $e");
      return null;
    }
  }
}