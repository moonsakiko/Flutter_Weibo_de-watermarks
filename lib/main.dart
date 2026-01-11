import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:fluttertoast/fluttertoast.dart';
import 'package:image_picker/image_picker.dart';
import 'package:file_picker/file_picker.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart'; // 需添加依赖
import 'dart:io';
import 'utils/weibo_api.dart';

void main() {
  runApp(const MyApp());
}

class MyApp extends StatefulWidget {
  const MyApp({super.key});

  @override
  State<MyApp> createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> {
  Color _seedColor = Colors.teal; // 默认青色

  @override
  void initState() {
    super.initState();
    _loadTheme();
  }

  Future<void> _loadTheme() async {
    final prefs = await SharedPreferences.getInstance();
    final colorVal = prefs.getInt('theme_color') ?? Colors.teal.value;
    setState(() => _seedColor = Color(colorVal));
  }

  void _changeTheme(Color color) async {
    setState(() => _seedColor = color);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt('theme_color', color.value);
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Weibo Cleaner',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(seedColor: _seedColor, brightness: Brightness.light),
        scaffoldBackgroundColor: const Color(0xFFF5F7FA),
        appBarTheme: AppBarTheme(
          backgroundColor: _seedColor,
          foregroundColor: Colors.white,
          elevation: 0,
        ),
      ),
      home: HomePage(onThemeChanged: _changeTheme),
    );
  }
}

class HomePage extends StatefulWidget {
  final Function(Color) onThemeChanged;
  const HomePage({super.key, required this.onThemeChanged});

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
    _requestPermissionsDirectly();
  }

  Future<void> _requestPermissionsDirectly() async {
    await [Permission.storage, Permission.photos, Permission.manageExternalStorage].request();
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
      _addLog("⚙️ 呼叫原生引擎...");
      final result = await platform.invokeMethod('processImages', {
        'tasks': tasks,
        'confidence': _confidence,
        'padding': _paddingRatio,
      });
      
      if (result is Map && result.containsKey('logs')) {
         // 这里只简单显示Native Log的前500字符防止刷屏，或者根据需求显示
         // _addLog("[Native]: ${result['logs']}"); 
      }

      int count = result is Map ? result['count'] : 0;
      if (count > 0) {
        _addLog("🎉 成功修复 $count 张");
        Fluttertoast.showToast(msg: "成功修复 $count 张");
      } else {
        _addLog("⚠️ 0 张被修复。请调整置信度或区域。");
      }
    } on PlatformException catch (e) {
      _addLog("❌ 崩溃: ${e.message}");
    } finally {
      setState(() => _isProcessing = false);
    }
  }

  Future<void> _handleLinkDownload() async {
    String link = _linkController.text.trim();
    if (link.isEmpty) return;
    FocusScope.of(context).unfocus();
    setState(() => _isProcessing = true);
    
    _addLog("🌐 正在解析...");
    String? wid = await WeiboApi.getWeiboId(link);
    
    if (wid == null) {
      _addLog("❌ ID解析失败，尝试手动复制长链接");
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

  // Pickers
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
  }

  void _showSkinDialog() {
    showDialog(context: context, builder: (ctx) => AlertDialog(
      title: const Text("选择主题色"),
      content: Wrap(
        spacing: 10,
        children: [
          _colorBtn(Colors.teal),
          _colorBtn(Colors.pinkAccent),
          _colorBtn(Colors.blueAccent),
          _colorBtn(Colors.orange),
          _colorBtn(Colors.indigo),
          _colorBtn(Colors.black87),
        ],
      ),
    ));
  }

  Widget _colorBtn(Color c) {
    return GestureDetector(
      onTap: () {
        widget.onThemeChanged(c);
        Navigator.pop(context);
      },
      child: Container(width: 40, height: 40, margin: const EdgeInsets.only(bottom: 10), decoration: BoxDecoration(color: c, shape: BoxShape.circle)),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text("Weibo Cleaner", style: TextStyle(fontWeight: FontWeight.bold)),
        actions: [
          IconButton(icon: const Icon(Icons.palette), onPressed: _showSkinDialog),
        ],
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
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.05), blurRadius: 10)],
      ),
      child: Scrollbar(
        child: SingleChildScrollView(
          controller: _logScrollController,
          child: Text(
            _log,
            style: TextStyle(
              color: Colors.grey[800],
              fontFamily: "monospace",
              fontSize: 11,
            ),
          ),
        ),
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
            decoration: const InputDecoration(
              hintText: "支持 mapp/share 短链",
              border: OutlineInputBorder(),
              prefixIcon: Icon(Icons.link),
            ),
          ),
          const SizedBox(height: 16),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: _isProcessing ? null : _handleLinkDownload,
              icon: const Icon(Icons.download),
              label: const Text("提取并修复"),
              style: FilledButton.styleFrom(padding: const EdgeInsets.symmetric(vertical: 12)),
            ),
          ),
        ],
      ),
    );
  }

  // SingleTab, BatchTab (逻辑未变，直接复用或根据主题自适应颜色)
  // 此处省略重复代码，与上一版一致，Flutter会自动应用 Theme 颜色
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
            FilledButton(
              onPressed: _isProcessing ? null : _runSingleRepair,
              child: const Text("执行修复"),
            )
          ],
        ),
      );
  }

  Widget _buildBatchTab() {
      return Center(
        child: FilledButton.icon(
          onPressed: _isProcessing ? null : _pickBatch,
          icon: const Icon(Icons.folder_open),
          label: const Text("批量选择"),
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
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: Colors.grey.shade300),
            image: path != null ? DecorationImage(image: FileImage(File(path)), fit: BoxFit.cover) : null,
          ),
          child: path == null ? Center(child: Text(label)) : null,
        ),
      );
  }
}