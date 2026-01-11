import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:fluttertoast/fluttertoast.dart';
import 'package:image_picker/image_picker.dart';
import 'package:file_picker/file_picker.dart';
import 'package:permission_handler/permission_handler.dart';
import 'dart:io';
import 'utils/weibo_api.dart';

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '微博去水印',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        // 🎨 改为冷峻的青色 (Teal)
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.teal, brightness: Brightness.light),
        scaffoldBackgroundColor: const Color(0xFFF0F2F5),
        appBarTheme: const AppBarTheme(
          backgroundColor: Colors.teal,
          foregroundColor: Colors.white,
          elevation: 2,
        ),
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

  double _confidence = 0.4;
  double _paddingRatio = 0.1;
  
  final ScrollController _logScrollController = ScrollController();
  String _log = "系统就绪。";
  bool _isProcessing = false;
  final TextEditingController _linkController = TextEditingController();

  String? _singleWmPath;
  String? _singleOrigPath;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 3, vsync: this);
    // 🛡️ 启动即请求权限，不废话
    _requestPermissionsDirectly();
  }

  Future<void> _requestPermissionsDirectly() async {
    await [
      Permission.storage,
      Permission.photos,
      Permission.manageExternalStorage, // 尝试请求所有可能需要的
    ].request();
  }

  void _addLog(String msg) {
    if (!mounted) return;
    setState(() => _log = "$_log\n$msg");
    Future.delayed(const Duration(milliseconds: 100), () {
      if (_logScrollController.hasClients) {
        _logScrollController.animateTo(
          _logScrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
        );
      }
    });
  }

  Future<void> _runRepair(List<Map<String, String>> tasks) async {
    if (tasks.isEmpty) return;
    setState(() => _isProcessing = true);
    try {
      _addLog("⚙️ 呼叫原生引擎 (Conf: ${_confidence.toStringAsFixed(2)})...");
      
      final result = await platform.invokeMethod('processImages', {
        'tasks': tasks,
        'confidence': _confidence,
        'padding': _paddingRatio,
      });
      
      // 解析返回结果，如果包含 logs 字段则打印原生调试日志
      if (result is Map && result.containsKey('logs')) {
         _addLog("\n🔍 [Native Logs]:\n${result['logs']}");
      }

      int count = 0;
      if (result is Map && result.containsKey('count')) {
         count = result['count'];
      }

      if (count > 0) {
        _addLog("🎉 成功修复 $count 张，已存入相册");
        Fluttertoast.showToast(msg: "成功修复 $count 张");
      } else {
        _addLog("⚠️ 0 张被修复。请检查 Native Log 确认模型是否工作。");
      }
    } on PlatformException catch (e) {
      _addLog("❌ 崩溃: ${e.message}");
    } finally {
      setState(() => _isProcessing = false);
    }
  }

  // ... (链接下载逻辑与之前类似，但调用新的 API)
  Future<void> _handleLinkDownload() async {
    String link = _linkController.text.trim();
    if (link.isEmpty) return;
    FocusScope.of(context).unfocus();
    setState(() => _isProcessing = true);
    
    _addLog("🌐 正在解析...");
    String? wid = await WeiboApi.getWeiboId(link);
    
    if (wid == null) {
      _addLog("❌ ID解析失败，请检查链接");
      setState(() => _isProcessing = false);
      return;
    }
    
    _addLog("🆔 ID: $wid，获取图片...");
    var urls = await WeiboApi.getImageUrls(wid);
    if (urls.isEmpty) {
      _addLog("⚠️ 无图片");
      setState(() => _isProcessing = false);
      return;
    }

    _addLog("📦 下载 ${urls.length} 张...");
    List<Map<String, String>> localTasks = [];
    for (var item in urls) {
      var pair = await WeiboApi.downloadPair(item, (msg) => _addLog(msg));
      if (pair != null) localTasks.add(pair);
    }

    if (localTasks.isNotEmpty) {
      _addLog("🚀 开始修复...");
      await _runRepair(localTasks);
    } else {
      setState(() => _isProcessing = false);
    }
  }

  // ... (PickSingle, PickBatch 保持不变，代码略以节省篇幅，直接复制之前的逻辑即可)
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
      Fluttertoast.showToast(msg: "需选择两张图片");
    }
  }

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
        String expectedOrig = wm.replaceAll("-wm.", "-orig.");
        if (files.contains(expectedOrig)) {
          tasks.add({'wm': wm, 'clean': expectedOrig});
        }
      }
      if (tasks.isEmpty) {
        _addLog("⚠️ 未匹配到成对图片 (-wm/-orig)");
      } else {
        _addLog("🔗 匹配 ${tasks.length} 对");
        _runRepair(tasks);
      }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text("Weibo Cleaner", style: TextStyle(fontWeight: FontWeight.bold)),
        bottom: TabBar(
          controller: _tabController,
          indicatorColor: Colors.white,
          tabs: const [Tab(text: "链接"), Tab(text: "单张"), Tab(text: "批量")],
        ),
      ),
      body: Column(
        children: [
          _buildControlPanel(),
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
          _buildLogArea(),
        ],
      ),
    );
  }

  Widget _buildControlPanel() {
    return Container(
      color: Colors.white,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Column(
        children: [
          Row(
            children: [
              const Text("置信度", style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
              Expanded(
                child: Slider(
                  value: _confidence, min: 0.1, max: 0.9, divisions: 8,
                  label: _confidence.toString(),
                  onChanged: (v) => setState(() => _confidence = v),
                ),
              ),
              Text("${(_confidence * 100).toInt()}%", style: const TextStyle(fontSize: 12)),
            ],
          ),
          Row(
            children: [
              const Text("扩大区域", style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
              Expanded(
                child: Slider(
                  value: _paddingRatio, min: 0.0, max: 0.5, divisions: 10,
                  label: _paddingRatio.toString(),
                  onChanged: (v) => setState(() => _paddingRatio = v),
                ),
              ),
              Text("${(_paddingRatio * 100).toInt()}%", style: const TextStyle(fontSize: 12)),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildLogArea() {
    return Container(
      height: 140,
      width: double.infinity,
      margin: const EdgeInsets.all(12),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.9), // 🤍 改为白色半透明
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.grey.shade300),
        boxShadow: [BoxShadow(color: Colors.black12, blurRadius: 5)],
      ),
      child: Scrollbar(
        child: SingleChildScrollView(
          controller: _logScrollController,
          child: Text(
            _log,
            style: TextStyle(
              color: Colors.grey[800], // 🖋️ 深灰字体，清晰易读
              fontFamily: "monospace",
              fontSize: 11,
            ),
          ),
        ),
      ),
    );
  }

  // ... (LinkTab, SingleTab, BatchTab 的构建逻辑与之前相同，主要是配色变化，不再赘述占用篇幅)
  // 请直接复用之前的 Widget 代码，将 ElevatedButton 的 style 改为 Colors.teal 即可
    Widget _buildLinkTab() {
    return Padding(
      padding: const EdgeInsets.all(16.0),
      child: Column(
        children: [
          TextField(
            controller: _linkController,
            decoration: const InputDecoration(
              labelText: "微博链接",
              hintText: "支持 mapp 短链",
              border: OutlineInputBorder(),
              prefixIcon: Icon(Icons.link),
            ),
          ),
          const SizedBox(height: 16),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton.icon(
              onPressed: _isProcessing ? null : _handleLinkDownload,
              icon: const Icon(Icons.download),
              label: const Text("提取并修复"),
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.teal,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 12),
              ),
            ),
          ),
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
              _imgBox("水印图", _singleWmPath, true),
              const Icon(Icons.arrow_forward),
              _imgBox("原图", _singleOrigPath, false),
            ],
          ),
          const SizedBox(height: 20),
          ElevatedButton(
            onPressed: _isProcessing ? null : _runSingleRepair,
            style: ElevatedButton.styleFrom(backgroundColor: Colors.teal, foregroundColor: Colors.white),
            child: const Text("执行修复"),
          )
        ],
      ),
    );
  }

  Widget _buildBatchTab() {
     return Center(
       child: ElevatedButton.icon(
         onPressed: _isProcessing ? null : _pickBatch,
         icon: const Icon(Icons.folder_open),
         label: const Text("批量选择"),
          style: ElevatedButton.styleFrom(backgroundColor: Colors.teal, foregroundColor: Colors.white),
       ),
     );
  }

  Widget _imgBox(String label, String? path, bool isWm) {
    return GestureDetector(
      onTap: () => _pickSingle(isWm),
      child: Container(
        width: 100, height: 100,
        decoration: BoxDecoration(
          color: Colors.white,
          border: Border.all(color: Colors.grey.shade300),
          borderRadius: BorderRadius.circular(8),
          image: path != null ? DecorationImage(image: FileImage(File(path)), fit: BoxFit.cover) : null,
        ),
        child: path == null ? Center(child: Text(label)) : null,
      ),
    );
  }
}