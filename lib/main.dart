import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:fluttertoast/fluttertoast.dart';
import 'package:image_picker/image_picker.dart';
import 'package:file_picker/file_picker.dart';
import 'package:permission_handler/permission_handler.dart';
import 'dart:io';
import 'dart:async'; // 引入 Timer
import 'utils/weibo_api.dart';

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '微博去水印神器',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        // 使用更现代的配色
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFFFA709A), // 骚粉/微博红
          brightness: Brightness.light,
        ),
        scaffoldBackgroundColor: const Color(0xFFF5F5F7), // 苹果灰背景
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
  double _paddingRatio = 0.2; // 默认稍微扩大一点，效果更好
  
  // 日志相关
  final ScrollController _logScrollController = ScrollController();
  String _log = "🚀 系统初始化完成...\n等待指令...";
  bool _isProcessing = false;
  
  final TextEditingController _linkController = TextEditingController();

  // 单张模式变量
  String? _singleWmPath;
  String? _singleOrigPath;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 3, vsync: this);
    // 启动时立即检查权限
    _checkPermissions();
  }

  /// 🛡️ 强力权限请求
  Future<void> _checkPermissions() async {
    // 针对 Android 13+ 和 旧版本分别处理
    Map<Permission, PermissionStatus> statuses = await [
      Permission.storage,
      Permission.photos,
      Permission.manageExternalStorage, // 部分旧机型可能需要
    ].request();
    
    bool isGranted = statuses.values.any((s) => s.isGranted);
    if (!isGranted) {
      _addLog("⚠️ 警告：存储权限未授予，可能无法保存图片！");
      // 弹窗提示去设置
      if (mounted) {
        showDialog(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text("需要权限"),
            content: const Text("为了读取相册和保存修复后的图片，请授予存储权限。"),
            actions: [
              TextButton(onPressed: () => Navigator.pop(ctx), child: const Text("取消")),
              TextButton(
                onPressed: () {
                  Navigator.pop(ctx);
                  openAppSettings();
                },
                child: const Text("去设置"),
              ),
            ],
          ),
        );
      }
    } else {
      _addLog("✅ 存储权限已获取");
    }
  }

  void _addLog(String msg) {
    if (!mounted) return;
    setState(() {
      _log = "$_log\n> $msg";
    });
    // 自动滚动到底部
    Future.delayed(const Duration(milliseconds: 100), () {
      if (_logScrollController.hasClients) {
        _logScrollController.animateTo(
          _logScrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOut,
        );
      }
    });
  }

  // --- 核心调用 Native 方法 ---
  Future<void> _runRepair(List<Map<String, String>> tasks) async {
    if (tasks.isEmpty) return;
    setState(() => _isProcessing = true);
    
    try {
      _addLog("⚙️ 启动 AI 引擎 (Conf: ${_confidence.toStringAsFixed(2)}, Pad: ${_paddingRatio.toStringAsFixed(2)})...");
      
      final result = await platform.invokeMethod('processImages', {
        'tasks': tasks,
        'confidence': _confidence,
        'padding': _paddingRatio,
      });
      
      int count = result['count'];
      if (count > 0) {
        _addLog("🎉 成功修复 $count 张！已保存到相册/Pictures/WeiboCleaned");
        Fluttertoast.showToast(msg: "成功修复 $count 张", backgroundColor: Colors.green);
      } else {
        _addLog("⚠️ 0 张被修复。建议：\n1. 调低置信度\n2. 调大区域扩大\n3. 确认图片是否真有水印");
        Fluttertoast.showToast(msg: "未检测到水印", backgroundColor: Colors.orange);
      }
      
    } on PlatformException catch (e) {
      _addLog("❌ 错误: ${e.message}");
    } finally {
      setState(() => _isProcessing = false);
    }
  }

  // --- 功能 1: 链接自动下载并处理 ---
  Future<void> _handleLinkDownload() async {
    String link = _linkController.text.trim();
    if (link.isEmpty) {
      Fluttertoast.showToast(msg: "请先粘贴链接");
      return;
    }
    FocusScope.of(context).unfocus();

    setState(() => _isProcessing = true);
    _addLog("🔍 正在解析链接 (自动追踪重定向)...");
    
    // 1. 获取 ID (支持 mapp/share 等短链)
    String? wid = await WeiboApi.getWeiboId(link);
    
    if (wid == null) {
      _addLog("❌ 解析失败！请确保链接包含微博内容。\n尝试在浏览器打开链接，复制地址栏的长链接重试。");
      setState(() => _isProcessing = false);
      return;
    }

    _addLog("🆔 捕获微博ID: $wid");
    
    // 2. 获取图片列表
    var urls = await WeiboApi.getImageUrls(wid);
    if (urls.isEmpty) {
      _addLog("⚠️ 未找到图片 (可能是视频/转发/被删)");
      setState(() => _isProcessing = false);
      return;
    }
    _addLog("📦 发现 ${urls.length} 张图片，开始下载...");

    // 3. 下载图片对
    List<Map<String, String>> localTasks = [];
    int successCount = 0;
    
    for (var i = 0; i < urls.length; i++) {
      var item = urls[i];
      _addLog("⬇️ 下载第 ${i+1}/${urls.length} 张...");
      var pair = await WeiboApi.downloadPair(item, (status) {});
      
      if (pair != null) {
        localTasks.add(pair);
        successCount++;
      } else {
        _addLog("❌ 第 ${i+1} 张下载失败");
      }
    }

    if (successCount > 0) {
      _addLog("✅ 下载完成，开始 AI 去水印...");
      await _runRepair(localTasks);
    } else {
      _addLog("❌ 所有图片下载失败");
      setState(() => _isProcessing = false);
    }
  }

  // ... (单张/批量选择逻辑保持不变，略微简化代码展示)
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

  Future<void> _pickBatch() async {
    FilePickerResult? result = await FilePicker.platform.pickFiles(allowMultiple: true, type: FileType.image);
    if (result != null) {
      List<String> files = result.paths.whereType<String>().toList();
      List<Map<String, String>> tasks = [];
      List<String> wmFiles = files.where((f) => f.contains("-wm.")).toList();
      for (var wm in wmFiles) {
        String expectedOrig = wm.replaceAll("-wm.", "-orig.");
        if (files.contains(expectedOrig)) {
          tasks.add({'wm': wm, 'clean': expectedOrig});
        }
      }
      if (tasks.isEmpty) {
        _addLog("⚠️ 未匹配到文件。文件名需包含 -wm 和 -orig");
      } else {
        _addLog("🔗 匹配到 ${tasks.length} 对图片");
        _runRepair(tasks);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text("微博去水印神器", style: TextStyle(fontWeight: FontWeight.bold)),
        elevation: 0,
        backgroundColor: Colors.white,
        foregroundColor: Colors.black,
        bottom: TabBar(
          controller: _tabController,
          labelColor: const Color(0xFFFA709A),
          unselectedLabelColor: Colors.grey,
          indicatorColor: const Color(0xFFFA709A),
          tabs: const [
            Tab(text: "链接提取"),
            Tab(text: "单张精修"),
            Tab(text: "批量处理"),
          ],
        ),
      ),
      body: Column(
        children: [
          // 🎛️ 1. 控制面板 (所有模式通用)
          _buildControlPanel(),

          // 📄 2. 功能区
          Expanded(
            child: TabBarView(
              controller: _tabController,
              children: [
                _buildLinkTab(),
                _buildSingleTab(),
                _buildBatchTab(),
              ],
            ),
          ),

          // 📟 3. 美化后的日志框
          _buildLogConsole(),
        ],
      ),
    );
  }

  // --- UI 组件封装 ---

  Widget _buildControlPanel() {
    return Container(
      margin: const EdgeInsets.all(12),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        boxShadow: [
          BoxShadow(color: Colors.black.withOpacity(0.05), blurRadius: 10, offset: const Offset(0, 4))
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.tune, size: 16, color: Colors.grey),
              const SizedBox(width: 8),
              Text("AI 参数微调", style: TextStyle(fontWeight: FontWeight.bold, color: Colors.grey[800])),
            ],
          ),
          const Divider(height: 16),
          // 置信度滑块
          Row(
            children: [
              const Text("置信度:", style: TextStyle(fontSize: 12)),
              Expanded(
                child: Slider(
                  value: _confidence,
                  min: 0.1, max: 0.9, divisions: 8,
                  label: _confidence.toString(),
                  activeColor: const Color(0xFFFA709A),
                  onChanged: (v) => setState(() => _confidence = v),
                ),
              ),
              Text("${(_confidence * 100).toInt()}%", style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
            ],
          ),
          // 区域扩大滑块
          Row(
            children: [
              const Text("扩大区域:", style: TextStyle(fontSize: 12)),
              Expanded(
                child: Slider(
                  value: _paddingRatio,
                  min: 0.0, max: 0.5, divisions: 10,
                  label: _paddingRatio.toString(),
                  activeColor: Colors.blueAccent,
                  onChanged: (v) => setState(() => _paddingRatio = v),
                ),
              ),
              Text("${(_paddingRatio * 100).toInt()}%", style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildLinkTab() {
    return Padding(
      padding: const EdgeInsets.all(16.0),
      child: Column(
        children: [
          TextField(
            controller: _linkController,
            decoration: InputDecoration(
              hintText: "在此粘贴微博分享链接...",
              filled: true,
              fillColor: Colors.white,
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
              prefixIcon: const Icon(Icons.link),
              suffixIcon: IconButton(
                icon: const Icon(Icons.content_paste, color: Color(0xFFFA709A)),
                onPressed: () async {
                  ClipboardData? data = await Clipboard.getData(Clipboard.kTextPlain);
                  if (data != null) _linkController.text = data.text ?? "";
                },
              ),
            ),
          ),
          const SizedBox(height: 20),
          SizedBox(
            width: double.infinity,
            height: 50,
            child: ElevatedButton.icon(
              onPressed: _isProcessing ? null : _handleLinkDownload,
              icon: _isProcessing 
                  ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white)) 
                  : const Icon(Icons.auto_fix_high),
              label: Text(_isProcessing ? "处理中..." : "一键提取并修复", style: const TextStyle(fontSize: 16)),
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFFFA709A),
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              ),
            ),
          ),
          const SizedBox(height: 10),
          const Text("提示：支持短链接，如 mapp.api.weibo.cn", style: TextStyle(color: Colors.grey, fontSize: 12)),
        ],
      ),
    );
  }

  Widget _buildSingleTab() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              _imgBtn("水印图", _singleWmPath, true),
              const Icon(Icons.add_circle, color: Colors.grey),
              _imgBtn("原图", _singleOrigPath, false),
            ],
          ),
          const SizedBox(height: 30),
          ElevatedButton(
            onPressed: _isProcessing ? null : _runSingleRepair,
            style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFFFA709A),
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(horizontal: 40, vertical: 12)
            ),
            child: const Text("开始修复"),
          )
        ],
      ),
    );
  }

  Widget _buildBatchTab() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.folder_copy, size: 60, color: Colors.grey[300]),
          const SizedBox(height: 20),
          ElevatedButton.icon(
            onPressed: _isProcessing ? null : _pickBatch,
            icon: const Icon(Icons.file_open),
            label: const Text("选择多张图片 (自动配对)"),
            style: ElevatedButton.styleFrom(backgroundColor: Colors.blueAccent, foregroundColor: Colors.white),
          ),
          const Padding(
            padding: EdgeInsets.all(16.0),
            child: Text("注意：需确保文件名包含 -wm 和 -orig 才能自动配对", style: TextStyle(color: Colors.grey, fontSize: 12)),
          )
        ],
      ),
    );
  }

  Widget _imgBtn(String label, String? path, bool isWm) {
    return GestureDetector(
      onTap: () => _pickSingle(isWm),
      child: Column(
        children: [
          Container(
            width: 100, height: 100,
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: Colors.grey.withOpacity(0.3)),
              image: path != null ? DecorationImage(image: FileImage(File(path)), fit: BoxFit.cover) : null,
              boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.05), blurRadius: 5)]
            ),
            child: path == null ? Icon(Icons.image, size: 40, color: Colors.grey[300]) : null,
          ),
          const SizedBox(height: 8),
          Text(label, style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.grey)),
        ],
      ),
    );
  }

  Widget _buildLogConsole() {
    return Container(
      height: 150,
      width: double.infinity,
      margin: const EdgeInsets.all(12),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFF2B2B2B), // 深灰背景
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.white.withOpacity(0.1)),
      ),
      child: Scrollbar(
        child: SingleChildScrollView(
          controller: _logScrollController,
          child: Text(
            _log,
            style: const TextStyle(
              color: Color(0xFF00FF00), // 黑客绿
              fontFamily: "monospace",
              fontSize: 12,
              height: 1.4
            ),
          ),
        ),
      ),
    );
  }
}