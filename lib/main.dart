import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:fluttertoast/fluttertoast.dart';
import 'package:image_picker/image_picker.dart';
import 'package:file_picker/file_picker.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
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
  void initState() { super.initState(); _loadTheme(); }
  Future<void> _loadTheme() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() => _seedColor = Color(prefs.getInt('theme_color') ?? Colors.teal.value));
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

  InAppWebViewController? _webViewController;
  CookieManager _cookieManager = CookieManager.instance(); // 🍪 Cookie 管理器
  bool _isWebViewReady = false; 
  bool _isWebViewLoading = false;
  Timer? _webViewTimeout;

  double _confidence = 0.4;
  double _paddingRatio = 0.1;
  final ScrollController _logScrollController = ScrollController();
  String _log = "系统初始化...\n";
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
    // 🛡️ 降级权限：只请求基础存储权限
    await [Permission.storage, Permission.photos].request();
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

  Future<void> _startBrowserAnalysis(String url) async {
    if (!_isWebViewReady || _webViewController == null) {
      _addLog("⏳ 内核正在唤醒...");
      await Future.delayed(const Duration(seconds: 1));
      if (_webViewController == null) return;
    }

    _addLog("🕵️ 启动隐形侦察机...");
    _isWebViewLoading = true;
    _webViewTimeout?.cancel();
    _webViewTimeout = Timer(const Duration(seconds: 20), () { // 延长到20秒
      if (_isWebViewLoading) {
        _addLog("⏰ 解析超时");
        _stopBrowserAnalysis();
      }
    });

    _webViewController?.loadUrl(urlRequest: URLRequest(url: WebUri(url)));
  }

  void _stopBrowserAnalysis() {
    _isWebViewLoading = false;
    _webViewTimeout?.cancel();
    _webViewController?.stopLoading();
    setState(() => _isProcessing = false);
  }

  void _onWebViewUrlChanged(String? url) async {
    if (!_isWebViewLoading || url == null) return;
    String? id = WeiboApi.parseIdFromUrl(url);
    if (id != null) {
      _addLog("✅ 捕获真实ID: $id");
      
      // 🍪 核心操作：窃取 Cookie
      String cookieStr = "";
      try {
        List<Cookie> cookies = await _cookieManager.getCookies(url: WebUri(url));
        cookieStr = cookies.map((c) => "${c.name}=${c.value}").join("; ");
        // _addLog("🍪 凭证获取成功");
      } catch (e) {
        // _addLog("⚠️ 凭证获取失败，尝试无凭证访问");
      }

      _stopBrowserAnalysis();
      _webViewController?.loadUrl(urlRequest: URLRequest(url: WebUri("about:blank")));
      
      // 将 Cookie 传给 API
      await _startDownloadAndRepair(id, cookieStr);
    }
  }

  Future<void> _startDownloadAndRepair(String wid, String? cookie) async {
    setState(() => _isProcessing = true);
    _addLog("📦 获取图片列表...");
    
    // 使用窃取到的 Cookie 发起请求
    var urls = await WeiboApi.getImageUrls(wid, cookie: cookie);
    
    if (urls.isEmpty) {
      _addLog("⚠️ 无法获取图片 (可能需要登录或内容被删)");
      setState(() => _isProcessing = false);
      return;
    }

    _addLog("⬇️ 发现 ${urls.length} 张，下载中...");
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
    if (rawText.isEmpty) { Fluttertoast.showToast(msg: "请粘贴链接"); return; }
    FocusScope.of(context).unfocus();
    setState(() => _isProcessing = true);

    String? url = WeiboApi.extractUrlFromText(rawText);
    if (url == null) { _addLog("❌ 未发现链接"); setState(() => _isProcessing = false); return; }

    // 即使识别到 ID，也建议走浏览器获取 Cookie，除非是那种绝对公开的微博
    // 为了稳妥，统一走浏览器流程，反正 Pixel Mode 很快
    _startBrowserAnalysis(url);
  }

  // ... (UI Build 部分保持不变) ...
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      resizeToAvoidBottomInset: false,
      appBar: AppBar(title: const Text("Weibo Cleaner", style: TextStyle(fontWeight: FontWeight.bold)), actions: [IconButton(icon: const Icon(Icons.palette), onPressed: _showSkinDialog)], bottom: TabBar(controller: _tabController, indicatorColor: Colors.white, tabs: const [Tab(text: "链接"), Tab(text: "单张"), Tab(text: "批量")])),
      body: Stack(
        children: [
          Positioned(left: 0, top: 0, width: 10, height: 10, child: Opacity(opacity: 0.01, child: InAppWebView(
            initialSettings: InAppWebViewSettings(userAgent: "Mozilla/5.0 (iPhone; CPU iPhone OS 16_6 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/16.6 Mobile/15E148 Safari/604.1", javaScriptEnabled: true, useShouldOverrideUrlLoading: true, mediaPlaybackRequiresUserGesture: false, mixedContentMode: MixedContentMode.MIXED_CONTENT_ALWAYS_ALLOW),
            onWebViewCreated: (controller) { _webViewController = controller; _isWebViewReady = true; _addLog("✅ 内核装载成功 (Pixel Mode)"); },
            onLoadStop: (controller, url) => _onWebViewUrlChanged(url?.toString()),
            onUpdateVisitedHistory: (controller, url, isReload) => _onWebViewUrlChanged(url?.toString()),
          ))),
          Positioned.fill(child: Column(children: [_buildControlPanel(), Expanded(child: TabBarView(controller: _tabController, children: [_buildLinkTab(), _buildSingleTab(), _buildBatchTab()])), _buildLogArea()])),
        ],
      ),
    );
  }
  
  // (UI 组件与上一版一致，直接复用即可)
  Widget _buildLinkTab() { return Padding(padding: const EdgeInsets.all(16.0), child: Column(children: [TextField(controller: _linkController, decoration: InputDecoration(hintText: "在此粘贴微博链接", border: const OutlineInputBorder(), suffixIcon: IconButton(icon: const Icon(Icons.paste), onPressed: () async { ClipboardData? data = await Clipboard.getData(Clipboard.kTextPlain); if (data != null && data.text != null) _linkController.text = data.text!; }))), const SizedBox(height: 16), SizedBox(width: double.infinity, child: FilledButton.icon(onPressed: _isProcessing ? null : _handleLinkInput, icon: const Icon(Icons.download), label: const Text("一键提取并修复"), style: FilledButton.styleFrom(padding: const EdgeInsets.symmetric(vertical: 12))))])); }
  Widget _buildControlPanel() { return Container(color: Colors.white, padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8), child: Column(children: [Row(children: [const Text("置信度", style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold)), Expanded(child: Slider(value: _confidence, min: 0.1, max: 0.9, divisions: 8, onChanged: (v) => setState(() => _confidence = v))), Text("${(_confidence * 100).toInt()}%", style: const TextStyle(fontSize: 12))]), Row(children: [const Text("扩大区域", style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold)), Expanded(child: Slider(value: _paddingRatio, min: 0.0, max: 0.5, divisions: 10, onChanged: (v) => setState(() => _paddingRatio = v))), Text("${(_paddingRatio * 100).toInt()}%", style: const TextStyle(fontSize: 12))])])); }
  Widget _buildLogArea() { return Container(height: 140, width: double.infinity, margin: const EdgeInsets.all(12), padding: const EdgeInsets.all(12), decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(12), boxShadow: [BoxShadow(color: Colors.black12, blurRadius: 5)]), child: Scrollbar(child: SingleChildScrollView(controller: _logScrollController, child: Text(_log, style: TextStyle(color: Colors.grey[800], fontFamily: "monospace", fontSize: 11))))); }
  void _showSkinDialog() { showDialog(context: context, builder: (ctx) => AlertDialog(title: const Text("选择主题色"), content: Wrap(spacing: 10, children: [_colorBtn(Colors.teal), _colorBtn(Colors.pinkAccent), _colorBtn(Colors.blueAccent), _colorBtn(Colors.orange), _colorBtn(Colors.indigo), _colorBtn(Colors.black87)]))); }
  Widget _colorBtn(Color c) { return GestureDetector(onTap: () { widget.onThemeChanged(c); Navigator.pop(context); }, child: Container(width: 40, height: 40, margin: const EdgeInsets.only(bottom: 10), decoration: BoxDecoration(color: c, shape: BoxShape.circle))); }
  Future<void> _pickSingle(bool isWm) async { final ImagePicker picker = ImagePicker(); final XFile? image = await picker.pickImage(source: ImageSource.gallery); if (image != null) setState(() { if (isWm) _singleWmPath = image.path; else _singleOrigPath = image.path; }); }
  void _runSingleRepair() { if (_singleWmPath != null && _singleOrigPath != null) _runRepair([{'wm': _singleWmPath!, 'clean': _singleOrigPath!}]); else Fluttertoast.showToast(msg: "需选择两张图片"); }
  Future<void> _pickBatch() async { FilePickerResult? result = await FilePicker.platform.pickFiles(allowMultiple: true, type: FileType.image); if (result != null) { List<String> files = result.paths.whereType<String>().toList(); List<Map<String, String>> tasks = []; List<String> wmFiles = files.where((f) => f.contains("-wm.")).toList(); for (var wm in wmFiles) { String expectedOrig = wm.replaceAll("-wm.", "-orig."); if (files.contains(expectedOrig)) tasks.add({'wm': wm, 'clean': expectedOrig}); } if (tasks.isEmpty) _addLog("⚠️ 未匹配到成对图片"); else _runRepair(tasks); } }
  Widget _buildSingleTab() { return Center(child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [Row(mainAxisAlignment: MainAxisAlignment.spaceEvenly, children: [_imgBox("水印图", _singleWmPath, true), const Icon(Icons.arrow_forward), _imgBox("原图", _singleOrigPath, false)]), const SizedBox(height: 20), FilledButton(onPressed: _isProcessing ? null : _runSingleRepair, child: const Text("执行修复"))])); }
  Widget _buildBatchTab() { return Center(child: FilledButton.icon(onPressed: _isProcessing ? null : _pickBatch, icon: const Icon(Icons.folder_open), label: const Text("批量选择"))); }
  Widget _imgBox(String label, String? path, bool isWm) { return GestureDetector(onTap: () => _pickSingle(isWm), child: Container(width: 100, height: 100, decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(8), border: Border.all(color: Colors.grey.shade300), image: path != null ? DecorationImage(image: FileImage(File(path)), fit: BoxFit.cover) : null), child: path == null ? Center(child: Text(label)) : null)); }
}