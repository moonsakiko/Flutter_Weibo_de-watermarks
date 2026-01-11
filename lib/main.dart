import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:fluttertoast/fluttertoast.dart';
import 'package:image_picker/image_picker.dart';
import 'package:file_picker/file_picker.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart'; // 核心武器
import 'dart:io';
import 'dart:async';
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
  Color _seedColor = Colors.teal;
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
        appBarTheme: AppBarTheme(backgroundColor: _seedColor, foregroundColor: Colors.white, elevation: 0),
        filledButtonTheme: FilledButtonThemeData(style: FilledButton.styleFrom(backgroundColor: _seedColor, foregroundColor: Colors.white))
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

  // 浏览器控制相关
  InAppWebViewController? _webViewController;
  bool _isWebViewLoading = false;
  Timer? _webViewTimeout;

  double _confidence = 0.4;
  double _paddingRatio = 0.1;
  final ScrollController _logScrollController = ScrollController();
  String _log = "系统就绪。\n内核状态：等待启动...";
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
        _logScrollController.animateTo(_logScrollController.position.maxScrollExtent, duration: const Duration(milliseconds: 200), curve: Curves.easeOut);
      }
    });
  }

  // --- 核心修复流程 ---
  Future<void> _runRepair(List<Map<String, String>> tasks) async {
    if (tasks.isEmpty) return;
    setState(() => _isProcessing = true);
    try {
      _addLog("⚙️ 呼叫AI引擎...");
      final result = await platform.invokeMethod('processImages', {
        'tasks': tasks, 'confidence': _confidence, 'padding': _paddingRatio,
      });
      int count = result is Map ? result['count'] : 0;
      if (count > 0) {
        _addLog("🎉 成功修复 $count 张");
        Fluttertoast.showToast(msg: "成功修复 $count 张");
      } else {
        _addLog("⚠️ 0 张被修复。请调整置信度。");
      }
    } on PlatformException catch (e) {
      _addLog("❌ 崩溃: ${e.message}");
    } finally {
      setState(() => _isProcessing = false);
    }
  }

  // --- 核心：启动浏览器解析 ---
  Future<void> _startBrowserAnalysis(String url) async {
    if (_webViewController == null) {
      _addLog("❌ 浏览器内核未初始化，请重启APP");
      setState(() => _isProcessing = false);
      return;
    }

    _addLog("🕵️ 启动隐形侦察机，目标: $url");
    _isWebViewLoading = true;
    
    // 设置15秒超时
    _webViewTimeout?.cancel();
    _webViewTimeout = Timer(const Duration(seconds: 15), () {
      if (_isWebViewLoading) {
        _addLog("⏰ 解析超时。可能需要登录或网络不通。");
        _stopBrowserAnalysis();
      }
    });

    // 加载链接
    _webViewController?.loadUrl(urlRequest: URLRequest(url: WebUri(url)));
  }

  void _stopBrowserAnalysis() {
    _isWebViewLoading = false;
    _webViewTimeout?.cancel();
    _webViewController?.stopLoading();
    setState(() => _isProcessing = false);
  }

  // --- 浏览器回调：监听 URL 变化 ---
  void _onWebViewUrlChanged(String? url) async {
    if (!_isWebViewLoading || url == null) return;
    // print("Debug URL: $url"); // 调试用

    // 尝试提取 ID
    String? id = WeiboApi.parseIdFromUrl(url);
    if (id != null) {
      _addLog("✅ 捕获真实ID: $id");
      _stopBrowserAnalysis(); // 停止浏览器，节省资源
      await _startDownloadAndRepair(id);
    }
  }

  Future<void> _startDownloadAndRepair(String wid) async {
    setState(() => _isProcessing = true);
    _addLog("📦 获取图片列表...");
    var urls = await WeiboApi.getImageUrls(wid);
    if (urls.isEmpty) {
      _addLog("⚠️ 无法获取图片，可能是视频或被删除");
      setState(() => _isProcessing = false);
      return;
    }

    _addLog("⬇️ 发现 ${urls.length} 张，开始下载...");
    List<Map<String, String>> localTasks = [];
    for (var item in urls) {
      var pair = await WeiboApi.downloadPair(item, (msg) => _addLog(msg));
      if (pair != null) localTasks.add(pair);
    }

    if (localTasks.isNotEmpty) {
      await _runRepair(localTasks);
    } else {
      setState(() => _isProcessing = false);
    }
  }

  Future<void> _handleLinkInput() async {
    String rawText = _linkController.text.trim();
    if (rawText.isEmpty) {
      Fluttertoast.showToast(msg: "请粘贴链接");
      return;
    }
    FocusScope.of(context).unfocus();
    setState(() => _isProcessing = true);

    // 1. 简单的正则清洗
    String? url = WeiboApi.extractUrlFromText(rawText);
    if (url == null) {
      _addLog("❌ 格式错误：未发现链接。\n提示：请确保复制的是类似 http... 的内容");
      setState(() => _isProcessing = false);
      return;
    }

    // 2. 如果已经是最终 ID 链接，直接下载
    String? fastId = WeiboApi.parseIdFromUrl(url);
    if (fastId != null) {
      _addLog("⚡ 识别到直链 ID: $fastId");
      await _startDownloadAndRepair(fastId);
    } else {
      // 3. 如果是短链 (mapp/t.cn)，交给浏览器解析
      _startBrowserAnalysis(url);
    }
  }

  // ... (UI 构建部分) ...
  
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text("Weibo Cleaner", style: TextStyle(fontWeight: FontWeight.bold)),
        actions: [
          IconButton(icon: const Icon(Icons.palette), onPressed: _showSkinDialog),
        ],
        bottom: TabBar(controller: _tabController, indicatorColor: Colors.white, tabs: const [Tab(text: "链接"), Tab(text: "单张"), Tab(text: "批量")]),
      ),
      body: Stack(
        children: [
          Column(
            children: [
              _buildControlPanel(),
              Expanded(child: TabBarView(controller: _tabController, children: [_buildLinkTab(), _buildSingleTab(), _buildBatchTab()])),
              _buildLogArea(),
            ],
          ),
          
          // 👇👇👇 核心黑科技：肉眼不可见但真实存在的浏览器 👇👇👇
          Opacity(
            opacity: 0.0, // 完全透明
            child: SizedBox(
              width: 1, height: 1, // 极小尺寸，不占布局
              child: InAppWebView(
                initialSettings: InAppWebViewSettings(
                  userAgent: "Mozilla/5.0 (iPhone; CPU iPhone OS 16_6 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/16.6 Mobile/15E148 Safari/604.1", // 伪装成 iPhone
                  javaScriptEnabled: true, // 必须开启 JS
                ),
                onWebViewCreated: (controller) {
                  _webViewController = controller;
                  _addLog("内核状态：已装载 (v6.0)");
                },
                onLoadStop: (controller, url) => _onWebViewUrlChanged(url?.toString()),
                onUpdateVisitedHistory: (controller, url, isReload) => _onWebViewUrlChanged(url?.toString()),
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ... (保留之前的 ControlPanel, LinkTab, SingleTab, BatchTab 等 UI 代码，无需变动) ...
  // 为完整性，这里贴出 LinkTab
  Widget _buildLinkTab() {
    return Padding(
      padding: const EdgeInsets.all(16.0),
      child: Column(
        children: [
          TextField(
            controller: _linkController,
            decoration: InputDecoration(
              hintText: "在此粘贴微博链接 (mapp/t.cn)",
              border: const OutlineInputBorder(),
              suffixIcon: IconButton(
                icon: const Icon(Icons.paste),
                onPressed: () async {
                  ClipboardData? data = await Clipboard.getData(Clipboard.kTextPlain);
                  if (data != null && data.text != null) _linkController.text = data.text!;
                }, 
              ),
            ),
          ),
          const SizedBox(height: 16),
          SizedBox(width: double.infinity, child: FilledButton.icon(
            onPressed: _isProcessing ? null : _handleLinkInput,
            icon: const Icon(Icons.download),
            label: const Text("一键提取并修复"),
            style: FilledButton.styleFrom(padding: const EdgeInsets.symmetric(vertical: 12)),
          )),
        ],
      ),
    );
  }
  
  // (ControlPanel, SingleTab, BatchTab, SkinDialog 逻辑与上一版完全一致，请直接复用)
  Widget _buildControlPanel() {
    return Container(
      color: Colors.white, padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Column(children: [
        Row(children: [const Text("置信度", style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold)), Expanded(child: Slider(value: _confidence, min: 0.1, max: 0.9, divisions: 8, onChanged: (v) => setState(() => _confidence = v))), Text("${(_confidence * 100).toInt()}%", style: const TextStyle(fontSize: 12))]),
        Row(children: [const Text("扩大区域", style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold)), Expanded(child: Slider(value: _paddingRatio, min: 0.0, max: 0.5, divisions: 10, onChanged: (v) => setState(() => _paddingRatio = v))), Text("${(_paddingRatio * 100).toInt()}%", style: const TextStyle(fontSize: 12))]),
      ]),
    );
  }
  
  Widget _buildLogArea() {
    return Container(height: 140, width: double.infinity, margin: const EdgeInsets.all(12), padding: const EdgeInsets.all(12), decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(12), boxShadow: [BoxShadow(color: Colors.black12, blurRadius: 5)]), child: Scrollbar(child: SingleChildScrollView(controller: _logScrollController, child: Text(_log, style: TextStyle(color: Colors.grey[800], fontFamily: "monospace", fontSize: 11)))));
  }

  void _showSkinDialog() { showDialog(context: context, builder: (ctx) => AlertDialog(title: const Text("选择主题色"), content: Wrap(spacing: 10, children: [_colorBtn(Colors.teal), _colorBtn(Colors.pinkAccent), _colorBtn(Colors.blueAccent), _colorBtn(Colors.orange), _colorBtn(Colors.indigo), _colorBtn(Colors.black87)]))); }
  Widget _colorBtn(Color c) { return GestureDetector(onTap: () { widget.onThemeChanged(c); Navigator.pop(context); }, child: Container(width: 40, height: 40, margin: const EdgeInsets.only(bottom: 10), decoration: BoxDecoration(color: c, shape: BoxShape.circle))); }
  
  Future<void> _pickSingle(bool isWm) async { final ImagePicker picker = ImagePicker(); final XFile? image = await picker.pickImage(source: ImageSource.gallery); if (image != null) setState(() { if (isWm) _singleWmPath = image.path; else _singleOrigPath = image.path; }); }
  void _runSingleRepair() { if (_singleWmPath != null && _singleOrigPath != null) _runRepair([{'wm': _singleWmPath!, 'clean': _singleOrigPath!}]); else Fluttertoast.showToast(msg: "需选择两张图片"); }
  Future<void> _pickBatch() async { FilePickerResult? result = await FilePicker.platform.pickFiles(allowMultiple: true, type: FileType.image); if (result != null) { List<String> files = result.paths.whereType<String>().toList(); List<Map<String, String>> tasks = []; List<String> wmFiles = files.where((f) => f.contains("-wm.")).toList(); for (var wm in wmFiles) { String expectedOrig = wm.replaceAll("-wm.", "-orig."); if (files.contains(expectedOrig)) tasks.add({'wm': wm, 'clean': expectedOrig}); } if (tasks.isEmpty) _addLog("⚠️ 未匹配到成对图片"); else _runRepair(tasks); } }
  Widget _buildSingleTab() { return Center(child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [Row(mainAxisAlignment: MainAxisAlignment.spaceEvenly, children: [_imgBox("水印图", _singleWmPath, true), const Icon(Icons.arrow_forward), _imgBox("原图", _singleOrigPath, false)]), const SizedBox(height: 20), FilledButton(onPressed: _isProcessing ? null : _runSingleRepair, child: const Text("执行修复"))])); }
  Widget _buildBatchTab() { return Center(child: FilledButton.icon(onPressed: _isProcessing ? null : _pickBatch, icon: const Icon(Icons.folder_open), label: const Text("批量选择"))); }
  Widget _imgBox(String label, String? path, bool isWm) { return GestureDetector(onTap: () => _pickSingle(isWm), child: Container(width: 100, height: 100, decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(8), border: Border.all(color: Colors.grey.shade300), image: path != null ? DecorationImage(image: FileImage(File(path)), fit: BoxFit.cover) : null), child: path == null ? Center(child: Text(label)) : null)); }
}