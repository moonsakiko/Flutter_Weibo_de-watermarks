import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:fluttertoast/fluttertoast.dart';
import 'package:image_picker/image_picker.dart';
import 'package:file_picker/file_picker.dart';
import 'package:permission_handler/permission_handler.dart';
import 'dart:io';
import 'utils/weibo_api.dart'; // 引入刚才写的网络模块

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '微博去水印神器', // 记得在 build.yml 改名
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.orange), // 微博橙
      ),
      home: const HomePage(),
    );
  }
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> with SingleTickerProviderStateMixin {
  late TabController _tabController;
  static const platform = MethodChannel('com.example.weibo_cleaner/processor');

  // 配置参数
  double _confidence = 0.5;
  double _paddingRatio = 0.1;
  String _log = "✅ 系统就绪\n等待指令...";
  bool _isProcessing = false;
  final TextEditingController _linkController = TextEditingController();

  // 单张模式变量
  String? _singleWmPath;
  String? _singleOrigPath;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 3, vsync: this);
    _requestPermissions();
  }

  Future<void> _requestPermissions() async {
    await [Permission.storage, Permission.photos].request();
  }

  void _addLog(String msg) {
    setState(() => _log = "$msg\n$_log");
  }

  // --- 核心调用 Native 方法 ---
  Future<void> _runRepair(List<Map<String, String>> tasks) async {
    if (tasks.isEmpty) return;
    setState(() => _isProcessing = true);
    
    try {
      _addLog("🚀 开始处理 ${tasks.length} 组任务...");
      final result = await platform.invokeMethod('processImages', {
        'tasks': tasks,
        'confidence': _confidence,
        'padding': _paddingRatio,
      });
      
      int count = result['count'];
      _addLog("🎉 处理完成！成功修复: $count 张");
      Fluttertoast.showToast(msg: "成功修复 $count 张，已保存到相册");
    } on PlatformException catch (e) {
      _addLog("❌ 错误: ${e.message}");
    } finally {
      setState(() => _isProcessing = false);
    }
  }

  // --- 功能 1: 链接自动下载并处理 ---
  Future<void> _handleLinkDownload() async {
    String link = _linkController.text.trim();
    if (link.isEmpty) return;
    FocusScope.of(context).unfocus();

    String? wid = WeiboApi.getWeiboId(link);
    if (wid == null) {
      _addLog("❌ 无法解析微博ID，请检查链接");
      return;
    }

    setState(() => _isProcessing = true);
    _addLog("🔍 解析微博ID: $wid");
    
    // 1. 获取图片列表
    var urls = await WeiboApi.getImageUrls(wid);
    if (urls.isEmpty) {
      _addLog("⚠️ 未找到图片或解析失败");
      setState(() => _isProcessing = false);
      return;
    }
    _addLog("📄 发现 ${urls.length} 张图片，准备下载...");

    // 2. 下载图片对
    List<Map<String, String>> localTasks = [];
    for (var i = 0; i < urls.length; i++) {
      var item = urls[i];
      var pair = await WeiboApi.downloadPair(item, (status) {
        // 更新下载进度不需要刷屏，简单打印即可
        print(status); 
      });
      
      if (pair != null) {
        localTasks.add(pair);
        _addLog("✅ 图片 ${i+1} 下载完毕");
      }
    }

    // 3. 调用原生去水印
    if (localTasks.isNotEmpty) {
      await _runRepair(localTasks);
    } else {
      setState(() => _isProcessing = false);
    }
  }

  // --- 功能 2: 单张手动选择 ---
  Future<void> _pickSingle(bool isWm) async {
    final ImagePicker picker = ImagePicker();
    final XFile? image = await picker.pickImage(source: ImageSource.gallery);
    if (image != null) {
      setState(() {
        if (isWm) _singleWmPath = image.path;
        else _singleOrigPath = image.path;
      });
    }
  }

  void _runSingleRepair() {
    if (_singleWmPath != null && _singleOrigPath != null) {
      _runRepair([{'wm': _singleWmPath!, 'clean': _singleOrigPath!}]);
    } else {
      Fluttertoast.showToast(msg: "请先选择两张图片");
    }
  }

  // --- 功能 3: 批量匹配 ---
  Future<void> _pickBatch() async {
    FilePickerResult? result = await FilePicker.platform.pickFiles(allowMultiple: true, type: FileType.image);
    if (result != null) {
      List<String> files = result.paths.whereType<String>().toList();
      _matchAndProcess(files);
    }
  }

  void _matchAndProcess(List<String> files) {
    List<Map<String, String>> tasks = [];
    List<String> wmFiles = files.where((f) => f.contains("-wm.")).toList();
    
    for (var wm in wmFiles) {
      // 尝试寻找对应的 -orig 文件
      String expectedOrig = wm.replaceAll("-wm.", "-orig.");
      if (files.contains(expectedOrig)) {
        tasks.add({'wm': wm, 'clean': expectedOrig});
      }
    }

    if (tasks.isEmpty) {
      _addLog("⚠️ 未匹配到成对的图片 (文件名需包含 -wm 和 -orig)");
    } else {
      _addLog("🔗 成功匹配 ${tasks.length} 对图片");
      _runRepair(tasks);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text("微博去水印神器"),
        bottom: TabBar(
          controller: _tabController,
          tabs: const [
            Tab(text: "链接提取", icon: Icon(Icons.link)),
            Tab(text: "单张精修", icon: Icon(Icons.compare)),
            Tab(text: "批量处理", icon: Icon(Icons.folder_copy)),
          ],
        ),
      ),
      body: Column(
        children: [
          Expanded(
            child: TabBarView(
              controller: _tabController,
              children: [
                // Tab 1: 链接提取
                Padding(
                  padding: const EdgeInsets.all(16.0),
                  child: Column(
                    children: [
                      TextField(
                        controller: _linkController,
                        decoration: InputDecoration(
                          hintText: "粘贴微博分享链接...",
                          border: OutlineInputBorder(),
                          suffixIcon: IconButton(
                            icon: Icon(Icons.paste),
                            onPressed: () async {
                              ClipboardData? data = await Clipboard.getData(Clipboard.kTextPlain);
                              if (data != null) _linkController.text = data.text ?? "";
                            },
                          ),
                        ),
                      ),
                      const SizedBox(height: 20),
                      FilledButton.icon(
                        onPressed: _isProcessing ? null : _handleLinkDownload,
                        icon: Icon(Icons.cloud_download),
                        label: Text(_isProcessing ? "处理中..." : "一键提取并修复"),
                        style: FilledButton.styleFrom(minimumSize: Size(double.infinity, 50)),
                      )
                    ],
                  ),
                ),
                
                // Tab 2: 单张
                Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                      children: [
                        _imgBtn("水印图", _singleWmPath, true),
                        Icon(Icons.add),
                        _imgBtn("原图", _singleOrigPath, false),
                      ],
                    ),
                    const SizedBox(height: 30),
                    FilledButton(
                      onPressed: _isProcessing ? null : _runSingleRepair,
                      child: Text("开始修复"),
                    )
                  ],
                ),

                // Tab 3: 批量
                Center(
                  child: FilledButton.icon(
                    onPressed: _isProcessing ? null : _pickBatch,
                    icon: Icon(Icons.file_open),
                    label: Text("选择多张图片 (自动配对)"),
                  ),
                ),
              ],
            ),
          ),
          
          // 底部日志栏
          Container(
            height: 120,
            width: double.infinity,
            color: Colors.black87,
            padding: EdgeInsets.all(8),
            child: SingleChildScrollView(
              reverse: true,
              child: Text(_log, style: TextStyle(color: Colors.greenAccent, fontFamily: "monospace")),
            ),
          )
        ],
      ),
    );
  }

  Widget _imgBtn(String label, String? path, bool isWm) {
    return GestureDetector(
      onTap: () => _pickSingle(isWm),
      child: Container(
        width: 100, height: 100,
        decoration: BoxDecoration(
          color: Colors.grey[300],
          border: Border.all(color: Colors.grey),
          image: path != null ? DecorationImage(image: FileImage(File(path)), fit: BoxFit.cover) : null
        ),
        child: path == null ? Center(child: Text(label)) : null,
      ),
    );
  }
}