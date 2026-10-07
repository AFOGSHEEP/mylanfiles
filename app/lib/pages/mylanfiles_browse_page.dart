import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:localsend_app/gen/strings.g.dart';
import 'package:localsend_app/pages/mylanfiles/photo_grid.dart';
import 'package:localsend_app/pages/mylanfiles/qr_scan_page.dart';
import 'package:localsend_app/pages/mylanfiles/transfer_queue.dart';
import 'package:mylanfiles_core/mylanfiles_core.dart';
import 'package:mylanfiles_server/mylanfiles_server.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:pretty_qr_code/pretty_qr_code.dart';


import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// MyLanFiles 浏览页（P1 垂直切片 3）：
/// - 「本机服务」：持久化自签 TLS 身份 + LAN 地址 + 二维码配对（§4.1 pair）
/// - 「连接远程」：粘贴二维码内容（JSON）→ 指纹 pin 握手 → 配对 → 浏览
/// - 「传输」：多选 → 自适应打包流（§4.2 中位 <2MiB）/ 逐文件 Range 续传，
///   队列串行执行 + 进度 UI；skip 断点续传（内容寻址，重传只补缺）
///
/// 不依赖上游 provider（fork 卫生，ADR-0002）；文案走上游 i18n 的 mlf
/// 命名空间（R8 起）；QR 用上游同一
/// 组件 pretty_qr_code 自建弹窗，不引入对上游 UI 外壳的依赖。
class MyLanFilesBrowsePage extends StatefulWidget {
  const MyLanFilesBrowsePage({super.key});

  @override
  State<MyLanFilesBrowsePage> createState() => _MyLanFilesBrowsePageState();
}

class _MyLanFilesBrowsePageState extends State<MyLanFilesBrowsePage> {
  // 本机服务
  MlfServer? _server;
  TlsIdentity? _identity;
  String? _lanIp;
  String? _rootPath;

  // 远程连接
  final _addressController = TextEditingController();
  MlfClient? _client;
  Uri? _remoteBase;
  final _clientFingerprint = devFingerprint('client');

  // 浏览与多选
  List<FsEntry> _entries = [];
  String _currentPath = '/';
  final Set<String> _selected = {};
  bool _busy = false;
  String? _error;

  // Android：所有文件访问（MANAGE）授予状态；null = 非 Android 或未查询
  bool? _manageGranted;

  // 上传全部结束后刷新目录列表（配对 _queue 监听）。
  bool _refreshAfterUploads = false;

  // 记忆化：已配对过的对端（客户端侧）与本机服务端口/配对表（服务端侧）。
  List<_RememberedServer> _servers = [];
  Directory? _identityDir;

  // 视图模式：文件列表 / 相册网格。
  bool _photosMode = false;

  // 自动发现：本机服务运行时宣告；浏览页打开时监听附近设备。
  DiscoveryAnnouncer? _announcer;
  DiscoveryListener? _listener;
  List<DiscoveredServer> _discovered = [];

  /// 当前 pin 的对端指纹（从地址栏解析出的配对信息）。
  String? _pinnedFp;

  final TransferQueue _queue = TransferQueue();

  @override
  void initState() {
    super.initState();
    _queue.addListener(_onQueueChanged);
    if (Platform.isAndroid) {
      _refreshManageStatus();
    }
    // 开发/联调捷径：MLF_AUTO_SERVER=1 启动即自动开服务并打印配对 JSON
    // （无人值守 E2E 用；不影响正常启动路径）。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(_loadRememberedServers().then((_) => _autoConnectLastUsed()));
      unawaited(_startDiscoveryListener());
    });
    if (Platform.environment['MLF_AUTO_SERVER'] == '1') {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        unawaited(_autoStartForE2E());
      });
    } else if (Platform.isAndroid) {
      // Android 联调捷径 A：mlf-server.flag 存在 → 本机直接开服务（反向场景：
      // 手机当服务端、PC 当客户端），配对 JSON 打进 logcat 供 PC 侧取用。
      // 联调捷径 B：mlf-pairing.json 存在 → 自动填入并连接远端。
      WidgetsBinding.instance.addPostFrameCallback((_) async {
        if (File('/storage/emulated/0/Download/mlf-server.flag').existsSync()) {
          await _autoStartForE2E();
        }
        if (File('/storage/emulated/0/Download/mlf-pairing.json').existsSync()) {
          await _autoPairFromFile();
        }
      });
    } else {
      // 桌面联调捷径：MLF_PAIR_FILE 指向配对 JSON → 自动连接（反向场景用），
      // 随后 MLF_DL_FILE / MLF_UL_FILE 触发无人值守传输。
      final pairFile = Platform.environment['MLF_PAIR_FILE'];
      if (pairFile != null && pairFile.isNotEmpty) {
        WidgetsBinding.instance.addPostFrameCallback((_) async {
          try {
            final raw = (await File(pairFile).readAsString()).trim();
            debugPrint('[MLF] pair-file loaded (${raw.length} chars)');
            _addressController.text = raw;
            await _connect();
            await _runDesktopManifests();
          } on Object catch (e) {
            debugPrint('[MLF] pair-file error: $e');
          }
        });
      }
    }
  }

  /// 执行桌面 E2E 清单：MLF_DL_FILE={"paths":[...],"mode":...} 下载；
  /// MLF_UL_FILE={"files":[本地路径...],"targetDir":"/x"} 上传。
  Future<void> _runDesktopManifests() async {
    if (_client == null || _remoteBase == null) {
      return;
    }
    final dl = Platform.environment['MLF_DL_FILE'];
    if (dl != null && File(dl).existsSync()) {
      try {
        final body = jsonDecode(File(dl).readAsStringSync()) as Map<dynamic, dynamic>;
        await _executeDownloadManifest(body);
      } on Object catch (e) {
        debugPrint('[MLF] dl-manifest error: ' + e.toString());
      }
    }
    final ul = Platform.environment['MLF_UL_FILE'];
    if (ul != null && File(ul).existsSync()) {
      try {
        final body = jsonDecode(File(ul).readAsStringSync()) as Map<dynamic, dynamic>;
        final files = (body['files'] as List?)?.cast<String>() ?? const [];
        final target = body['targetDir'] as String? ?? _currentPath;
        _refreshAfterUploads = true;
        for (final path in files) {
          final f = File(path);
          if (!f.existsSync()) {
            continue;
          }
          _queue.enqueue(
            TransferTask(
              label: '↑ ' + f.uri.pathSegments.last,
              kind: TransferKind.upload,
              totalBytes: f.lengthSync(),
              runner: (task) => _withReauth(() => _runUpload(task, f, target)),
            ),
          );
        }
        debugPrint('[MLF] ul-manifest: ' + files.length.toString() + ' files -> ' + target);
      } on Object catch (e) {
        debugPrint('[MLF] ul-manifest error: ' + e.toString());
      }
    }
  }

  Future<void> _autoPairFromFile() async {
    try {
      final f = File('/storage/emulated/0/Download/mlf-pairing.json');
      if (await f.exists()) {
        final raw = (await f.readAsString()).trim();
        debugPrint('[MLF] auto-pair file found (${raw.length} chars)');
        _addressController.text = raw;
        await _connect();
        await _autoDownloadFromFile();
      }
    } on Object catch (e) {
      debugPrint('[MLF] auto-pair file error: $e');
    }
  }

  /// E2E：配对后若存在 mlf-download.json（{"paths":[...]}），按路径入队打包下载。
  Future<void> _autoDownloadFromFile() async {
    if (_client == null || _remoteBase == null) {
      return;
    }
    try {
      final f = File('/storage/emulated/0/Download/mlf-download.json');
      if (!await f.exists()) {
        return;
      }
      final body = jsonDecode(await f.readAsString()) as Map<dynamic, dynamic>;
      await _executeDownloadManifest(body);
    } on Object catch (e) {
      debugPrint('[MLF] auto-download error: $e');
    }
  }

  /// 下载清单执行器（Android 文件 / 桌面 env 两条 E2E 路径共用）。
  /// manifest: {"paths":[...], "mode": "auto"|"sequential"|"pack"}
  Future<void> _executeDownloadManifest(Map<dynamic, dynamic> body) async {
    if (_client == null || _remoteBase == null) {
      return;
    }
    final paths = (body['paths'] as List?)?.cast<String>() ?? const [];
    if (paths.isEmpty) {
      return;
    }
    final wanted = paths.toSet();
    final wantedNames = paths.map((p) => p.split('/').last).toSet();
    var entries = <FsEntry>[];
    bool match(FsEntry e) => wanted.contains(e.path) || wanted.contains(e.name) || wantedNames.contains(e.name);
    for (final e in _entries) {
      if (match(e)) {
        entries.add(e);
      }
    }
    // 路径在子目录时：进入父目录再列一次匹配。
    if (entries.isEmpty && paths.first.contains('/')) {
      final parent = paths.first.substring(0, paths.first.lastIndexOf('/'));
      final dirEntries = await _client!.list(_remoteBase!, parent);
      debugPrint('[MLF] auto-download: listed parent $parent (${dirEntries.length})');
      for (final e in dirEntries) {
        if (match(e)) {
          entries.add(e);
        }
      }
    }
    debugPrint('[MLF] auto-download: ${entries.length}/${paths.length} matched');
    if (entries.isEmpty) {
      return;
    }
    final mode = body['mode'] as String? ?? 'auto';
    debugPrint('[MLF] auto-download mode: $mode');
    if (entries.length == 1 || mode == 'sequential') {
      for (final e in entries) {
        _enqueueDownload(e);
      }
    } else {
      await _enqueuePack(entries);
    }
  }

  Future<void> _autoStartForE2E() async {
    if (_server != null) {
      return;
    }
    if (Platform.isAndroid) {
      // 先等权限状态就绪再定共享根:否则 _sharedRoot 在 MANAGE 未查完时
      // 落到应用私有目录(真机反向 E2E 轮发现的竞态)。
      await _refreshManageStatus();
    }
    await _toggleServer();
    if (_server == null || _identity == null) {
      return;
    }
    final info = pairingInfoOf(_lanIp ?? '127.0.0.1');
    // 一行机器可读输出，脚本解析用。
    debugPrint('[MLF-PAIRING] ${jsonEncode(info.toJson())}');
  }

  Future<void> _refreshManageStatus() async {
    final status = await Permission.manageExternalStorage.status;
    if (mounted) {
      setState(() => _manageGranted = status.isGranted);
    }
  }

  /// Android 上请求「所有文件访问」（跳系统设置页），返回后重查状态。
  Future<void> _requestManage() async {
    await Permission.manageExternalStorage.request();
    await _refreshManageStatus();
  }

  @override
  void dispose() {
    _queue.removeListener(_onQueueChanged);
    unawaited(_listener?.stop());
    unawaited(_announcer?.stop());
    unawaited(_server?.stop());
    _client?.close();
    _queue.dispose();
    _addressController.dispose();
    super.dispose();
  }

  /// 收件箱（下载落地目录）。
  /// - Android 且已授 MANAGE：公开 Download/MyLanFiles-Inbox（用户可见可取）
  /// - 其余：下载目录（Windows）/应用外部目录（Android 无 MANAGE 时的降级）
  Future<Directory> _inboxDir() async {
    if (Platform.isAndroid && _manageGranted == true) {
      final inbox = Directory('/storage/emulated/0/Download/MyLanFiles-Inbox');
      if (!inbox.existsSync()) {
        inbox.createSync(recursive: true);
      }
      return inbox;
    }
    if (Platform.isAndroid) {
      final base = await getExternalStorageDirectory();
      final inbox = Directory('${base?.path ?? '/data/local/tmp'}/MyLanFiles-Inbox');
      if (!inbox.existsSync()) {
        inbox.createSync(recursive: true);
      }
      return inbox;
    }
    final base = await getDownloadsDirectory() ?? await getApplicationDocumentsDirectory();
    final inbox = Directory('${base.path}/MyLanFiles-Inbox');
    if (!inbox.existsSync()) {
      inbox.createSync(recursive: true);
    }
    return inbox;
  }

  /// 共享根：本端对外暴露的目录树起点。
  /// - Android 且已授 MANAGE：整个用户存储（产品的核心场景：手机相册/文件被浏览）
  /// - 其余：收件箱所在目录（演示配置，正式版改为用户可选）
  Future<String> _sharedRoot() async {
    if (Platform.isAndroid && _manageGranted == true) {
      return '/storage/emulated/0';
    }
    // E2E: MLF_ROOT 固定共享根（无人值守联调）。
    final envRoot = Platform.environment['MLF_ROOT'];
    if (envRoot != null && envRoot.isNotEmpty) {
      return envRoot;
    }
    final inbox = await _inboxDir();
    return inbox.parent.path;
  }

  // ---- 记忆化：服务端端口/配对表 + 客户端已配对设备 ----

  Future<File> _serverPrefsFile() async => File('${_identityDir!.path}/server.json');

  Future<Map<dynamic, dynamic>> _loadServerPrefs() async {
    try {
      final f = await _serverPrefsFile();
      if (await f.exists()) {
        return jsonDecode(await f.readAsString()) as Map<dynamic, dynamic>;
      }
    } on Object {
      /* 损坏则重来 */
    }
    return {};
  }

  Future<void> _saveServerPrefs(int port, Set<String> paired) async {
    try {
      final f = await _serverPrefsFile();
      await f.writeAsString(
        jsonEncode({'port': port, 'paired': paired.toList()}),
        flush: true,
      );
    } on Object catch (e) {
      debugPrint('[MLF] server-prefs save failed: ' + e.toString());
    }
  }

  Future<File> _pairedServersFile() async {
    final support = await getApplicationSupportDirectory();
    return File('${support.path}/paired-servers.json');
  }

  Future<void> _loadRememberedServers() async {
    try {
      final f = await _pairedServersFile();
      if (!await f.exists()) {
        return;
      }
      final body = jsonDecode(await f.readAsString()) as Map<dynamic, dynamic>;
      final list = (body['servers'] as List?) ?? const [];
      setState(() {
        _servers =
            list
                .map(
                  (m) => _RememberedServer.fromMap(m as Map<dynamic, dynamic>),
                )
                .toList()
              ..sort((a, b) => b.lastUsedMs.compareTo(a.lastUsedMs));
      });
    } on Object catch (e) {
      debugPrint('[MLF] load remembered servers failed: ' + e.toString());
    }
  }

  Future<void> _rememberServer(MlfPairingInfo info) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    // 别名优先级：本次 QR 携带 > 历史记忆 > IP。
    final previous = _servers.where((s) => s.fp == info.fingerprint).toList();
    final alias = info.alias?.isNotEmpty == true
        ? info.alias!
        : previous.isNotEmpty && previous.first.alias.isNotEmpty
        ? previous.first.alias
        : info.ip;
    setState(() {
      _servers
        ..removeWhere((s) => s.fp == info.fingerprint)
        ..insert(
          0,
          _RememberedServer(
            alias: alias,
            ip: info.ip,
            port: info.port,
            fp: info.fingerprint,
            lastUsedMs: now,
          ),
        );
    });
    try {
      final f = await _pairedServersFile();
      await f.writeAsString(
        jsonEncode({
          'servers': _servers.take(10).map((s) => s.toMap()).toList(), // 只记最近 10 台
        }),
        flush: true,
      );
    } on Object catch (e) {
      debugPrint('[MLF] save remembered servers failed: ' + e.toString());
    }
  }

  /// 设备别名：桌面=主机名；Android=机型（build.prop）。
  String _deviceAlias() {
    if (Platform.isAndroid) {
      try {
        final prop = File('/system/build.prop').readAsStringSync();
        final m = RegExp(r'ro[.]product[.]model=(.+)').firstMatch(prop);
        final model = m?.group(1)?.trim();
        if (model != null && model.isNotEmpty) {
          return model;
        }
      } on Object {
        /* fallthrough */
      }
      return t.mlf.androidDevice;
    }
    final h = Platform.localHostname;
    return h.isEmpty ? t.mlf.thisDevice : h;
  }

  // ---- 本机服务（TLS + QR 配对）----

  Future<void> _toggleServer() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      if (_server != null) {
        await _announcer?.stop();
        _announcer = null;
        await _server!.stop();
        _server = null;
        setState(() {});
        return;
      }
      // 身份持久化在应用私有目录（共享根之外，私钥不可经共享根泄露）。
      final support = await getApplicationSupportDirectory();
      _identityDir = Directory('${support.path}/identity');
      _identity = await loadOrCreateIdentity(_identityDir!);
      // 记忆化：复用上次端口（二维码/已配对设备跨重启有效）+ 已配对表。
      final prefs = await _loadServerPrefs();
      final savedPort = (prefs['port'] as num?)?.toInt() ?? 0;
      final savedPaired = ((prefs['paired'] as List?) ?? const []).whereType<String>().toSet();
      _rootPath = await _sharedRoot();
      final server = MlfServer(
        vfs: LocalVfs(root: _rootPath!),
        serverFingerprint: _identity!.fingerprint,
        pairedFingerprints: savedPaired,
        onPaired: (fp) {
          final s = _server;
          if (s != null) {
            unawaited(_saveServerPrefs(s.port, s.pairedFingerprints));
          }
        },
      );
      var bound = false;
      if (savedPort > 0) {
        try {
          await server.bind(
            InternetAddress.anyIPv4,
            savedPort,
            securityContext: _identity!.context,
          );
          bound = true;
        } on Object {
          debugPrint('[MLF] saved port $savedPort busy, using ephemeral');
        }
      }
      if (!bound) {
        await server.bind(
          InternetAddress.anyIPv4,
          0,
          securityContext: _identity!.context,
        );
      }
      await _saveServerPrefs(server.port, server.pairedFingerprints);
      _server = server;
      _lanIp = await lanIPv4();
      // 后台清理超龄断点文件(7 天+,不阻塞启动)。
      unawaited(
        cleanupStaleParts(server.vfs).then(
          (n) => n > 0 ? debugPrint('[MLF] cleaned $n stale .part files') : null,
        ),
      );
      debugPrint('[MLF] server up: $_lanIp:${server.port} root=$_rootPath');
      _startAnnouncer();
      setState(() {});
    } on Object catch (e) {
      setState(() => _error = t.mlf.errServerStart(error: e.toString()));
    } finally {
      setState(() => _busy = false);
    }
  }

  MlfPairingInfo pairingInfoOf(String ip) => MlfPairingInfo(
    ip: ip,
    port: _server?.port ?? 0,
    fingerprint: _identity?.fingerprint ?? '',
    alias: _deviceAlias(),
  );

  Future<void> _showPairingQr() async {
    final info = pairingInfoOf(_lanIp ?? '127.0.0.1');
    final json = const JsonEncoder.withIndent(' ').convert(info.toJson());
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(t.mlf.scanPair),
        content: SizedBox(
          width: 280,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                width: 220,
                height: 220,
                child: PrettyQrView.data(
                  errorCorrectLevel: QrErrorCorrectLevel.Q,
                  data: jsonEncode(info.toJson()),
                  decoration: PrettyQrDecoration(
                    shape: PrettyQrSmoothSymbol(
                      roundFactor: 0,
                      color: Theme.of(context).colorScheme.onSurface,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 12),
              SelectableText(
                'https://${info.ip}:${info.port}',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 4),
              SelectableText(
                t.mlf.fingerprintShort(fp: info.fingerprint.substring(0, 16)),
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(height: 8),
              SelectableText(
                json,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () async {
              await Clipboard.setData(
                ClipboardData(text: jsonEncode(info.toJson())),
              );
              if (context.mounted) {
                ScaffoldMessenger.of(
                  context,
                ).showSnackBar(SnackBar(content: Text(t.mlf.pairingCopied)));
              }
            },
            child: Text(t.mlf.copyPairing),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text(t.mlf.close),
          ),
        ],
      ),
    );
  }

  // ---- 自动发现（UDP 广播宣告/监听，大众化第一入口）----

  Future<void> _startDiscoveryListener() async {
    if (_listener != null) {
      return;
    }
    final listener = DiscoveryListener(
      onChanged: (servers) {
        // 发现日志带完整配对 JSON:对端是 release 构建(logcat 无输出)时,
        // PC 侧仍可从此行拿到 fp/port 完成无头对接。
        for (final d in servers) {
          debugPrint('[MLF] discovered: ' + d.pairingJson);
        }
        if (mounted) {
          setState(() => _discovered = servers);
        }
      },
    );
    try {
      await listener.start();
      _listener = listener;
      debugPrint('[MLF] discovery listener up');
    } on Object catch (e) {
      debugPrint('[MLF] discovery listener failed: ' + e.toString());
    }
  }

  void _startAnnouncer() {
    if (_server == null || _identity == null || _announcer != null) {
      return;
    }
    final announcer = DiscoveryAnnouncer(
      alias: _deviceAlias(),
      port: _server!.port,
      fingerprint: _identity!.fingerprint,
    );
    unawaited(announcer.start());
    _announcer = announcer;
    debugPrint('[MLF] announcing as ${_deviceAlias()}:${_server!.port}');
  }

  // ---- 远程连接（指纹 pin 握手）----

  /// 打开页面时静默重连上次使用的对端（记忆化的核心收益：零操作恢复）。
  Future<void> _autoConnectLastUsed() async {
    if (_servers.isEmpty || _addressController.text.isNotEmpty || _client != null) {
      return;
    }
    final last = _servers.first;
    debugPrint('[MLF] auto-reconnect: ' + last.alias);
    _addressController.text = last.pairingJson;
    await _connect();
  }

  Future<void> _connect() async {
    final raw = _addressController.text.trim();
    debugPrint('[MLF] connect tapped, raw=${raw.isEmpty ? "<empty>" : raw}');
    if (raw.isEmpty) {
      return;
    }
    final MlfPairingInfo info;
    try {
      info = MlfPairingInfo.parse(raw);
    } on FormatException catch (e) {
      setState(() => _error = t.mlf.errPairFormat(error: e.toString()));
      return;
    }
    if (!info.hasFingerprint) {
      setState(() => _error = t.mlf.errNoFingerprint);
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    _client?.close();
    _client = null;
    try {
      _pinnedFp = info.fingerprint;
      final client = MlfClient(pinnedFingerprint: info.fingerprint);
      // 握手即校验：证书指纹 ≠ 二维码指纹时 TLS 握手直接失败（§7 pin）。
      await client.pair(info.baseUri, _clientFingerprint);
      _client = client;
      _remoteBase = info.baseUri;
      debugPrint('[MLF] pair ok -> ${info.baseUri}');
      await _rememberServer(info);
      await _listDir('/');
      // E2E: MLF_PHOTOS=1 连接后直接切相册网格。
      if (Platform.environment['MLF_PHOTOS'] == '1') {
        setState(() => _photosMode = true);
      }
      setState(() {});
    } on Object catch (e) {
      debugPrint('[MLF] connect FAILED: $e');
      _remoteBase = null;
      setState(() => _error = t.mlf.errConnect(error: e.toString()));
    } finally {
      setState(() => _busy = false);
    }
  }

  /// 同机演示：连接本机正在运行的服务（loopback 免防火墙）。
  Future<void> _connectLocalDemo() async {
    if (_server == null || _identity == null) {
      return;
    }
    _addressController.text = jsonEncode(pairingInfoOf('127.0.0.1').toJson());
    await _connect();
  }

  Future<void> _listDir(String path) async {
    final entries = await _client!.list(_remoteBase!, path);
    debugPrint('[MLF] list ok: $path (${entries.length} entries)');
    setState(() {
      _entries = entries;
      _currentPath = path;
      _selected.clear();
    });
  }

  Future<void> _openEntry(FsEntry entry) async {
    if (entry.isDir) {
      setState(() => _busy = true);
      try {
        await _listDir(entry.path);
      } on Object catch (e) {
        setState(() => _error = '$e');
      } finally {
        setState(() => _busy = false);
      }
      return;
    }
    _enqueueDownload(entry);
  }

  // ---- 传输（队列 + 打包流/Range 续传）----

  /// 服务端重启后配对表丢失 → 403；自动重新 pair 一次再重试当前操作。
  Future<void> _withReauth(Future<void> Function() body) async {
    try {
      await body();
    } on MlfClientException catch (e) {
      if (!e.message.contains('403') || _client == null || _remoteBase == null) {
        rethrow;
      }
      await _client!.pair(_remoteBase!, _clientFingerprint);
      await body();
    }
  }

  void _throwIfCanceled(TransferTask task) {
    if (task.cancelRequested) {
      throw const TaskCanceledException();
    }
  }

  void _enqueueDownload(FsEntry entry) {
    _queue.enqueue(
      TransferTask(
        label: entry.name,
        kind: TransferKind.singleFile,
        totalBytes: entry.size,
        runner: (task) => _withReauth(() => _runDownload(task, entry)),
      ),
    );
  }

  /// 并行分块下载(Mathis 单流瓶颈 → 4 流叠加):仅全新下载且 ≥8MB 时启用。
  /// 任一块失败即删 `.part` 整体重来(并行写入存在洞,不保留断点);
  /// 串行路径保持原断点语义。
  static const _parallelChunks = 4;
  static const _parallelThreshold = 8 << 20;

  Future<void> _runParallelDownload(
    TransferTask task,
    FsEntry entry,
    File part,
  ) async {
    final size = entry.size;
    final raf = await part.open(mode: FileMode.write);
    await raf.truncate(size); // 预分配,块到位即偏移写入
    final chunk = (size + _parallelChunks - 1) ~/ _parallelChunks;
    // 单 RAF 上的偏移写必须串行化:setPosition+writeFrom 两步间会与其他
    // 块的 await 交错(真机踩雷:writeFrom 第二参是缓冲区下标而非文件偏移)。
    var writeChain = Future<void>.value();
    Future<void> lockedWriteAt(int pos, List<int> data) {
      writeChain = writeChain.then((_) async {
        await raf.setPosition(pos);
        await raf.writeFrom(data);
      });
      return writeChain;
    }

    final futures = <Future<void>>[];
    for (var i = 0; i < _parallelChunks; i++) {
      final start = i * chunk;
      final len = (i == _parallelChunks - 1) ? size - start : chunk;
      if (len <= 0) {
        break;
      }
      futures.add(() async {
        final res = await _client!.read(
          _remoteBase!,
          entry.path,
          offset: start,
          length: len,
        );
        var pos = start;
        await for (final data in res.stream) {
          _throwIfCanceled(task);
          task.addBytes(data.length);
          await lockedWriteAt(pos, data);
          pos += data.length;
        }
        if (pos != start + len) {
          throw MlfClientException('chunk $i short: ' + (pos - start).toString() + '/' + len.toString());
        }
      }());
    }
    try {
      await Future.wait(futures);
      await raf.flush();
    } finally {
      await raf.close();
    }
  }

  /// 逐文件下载，Range 断点续传：`.part` 落盘，失败保留，重试从
  /// offset=part 长度继续（§4.1 fs/read offset）。成功后原子改名。
  /// 远端文件比本地 .part 小（远端已变化）时丢弃 .part 从头重传。
  Future<void> _runDownload(TransferTask task, FsEntry entry) async {
    final inbox = await _inboxDir();
    final safeName = sanitizeFilename(entry.name);
    final part = File('${inbox.path}/$safeName.part');
    var offset = part.existsSync() ? await part.length() : 0;
    debugPrint('[MLF] download ${entry.name} @offset=$offset size=${entry.size}');
    // 大文件全新下载走 4 路并行(真机基线:单流 2.7MB/s);MLF_PARALLEL=0 关闭(A/B)。
    if (offset == 0 && entry.size >= _parallelThreshold && Platform.environment['MLF_PARALLEL'] != '0' && _client != null && _remoteBase != null) {
      final t0 = DateTime.now();
      try {
        await _runParallelDownload(task, entry, part);
      } on Object {
        if (part.existsSync()) {
          await part.delete(); // 并行半成品含洞,不保留断点
        }
        rethrow;
      }
      debugPrint(
        '[MLF] parallel done: ' + entry.name + ' in ' + DateTime.now().difference(t0).inMilliseconds.toString() + 'ms',
      );
      await _finalizePart(part, File('${inbox.path}/$safeName'));
      debugPrint('[MLF] download done: $safeName');
      return;
    }
    if (offset > entry.size) {
      await part.delete();
      offset = 0;
    }
    if (offset == entry.size && offset > 0) {
      // .part 已完整：直接落名（上次在改名前被打断的情形）。
      await _finalizePart(part, File('${inbox.path}/$safeName'));
      task.receivedBytes = entry.size;
      return;
    }
    if (offset > 0) {
      task.setDetail(t.mlf.resumeFrom(offset: formatBytes(offset)));
      task.receivedBytes = offset;
    }
    final t0 = DateTime.now();
    try {
      final res = await _client!.read(_remoteBase!, entry.path, offset: offset);
      final sink = part.openWrite(mode: FileMode.append);
      try {
        await sink.addStream(
          countBytes(res.stream, (d) {
            _throwIfCanceled(task);
            task.addBytes(d);
          }),
        );
        await sink.flush();
        await sink.close();
      } on Object {
        await sink.close();
        rethrow; // .part 保留，重试续传
      }
    } on MlfClientException catch (e) {
      // 远端比本地 .part 短（"offset past EOF"）：文件已变化，重置重传一次。
      if (e.message.contains('400') && offset > 0) {
        await part.delete();
        task.receivedBytes = 0;
        task.setDetail(t.mlf.remoteChanged);
        return _runDownload(task, entry);
      }
      rethrow;
    }
    await _finalizePart(part, File('${inbox.path}/$safeName'));
    debugPrint(
      '[MLF] serial done: ' + safeName + ' in ' + DateTime.now().difference(t0).inMilliseconds.toString() + 'ms',
    );
  }

  Future<void> _finalizePart(File part, File target) async {
    if (target.existsSync()) {
      await target.delete();
    }
    await part.rename(target.path);
  }

  /// 多选 → 打包流（§4.2）。skip = 收件箱中同名同尺寸文件的 SHA-256
  /// （内容寻址断点：服务端整帧跳过，重传只补缺）。
  Future<void> _enqueuePack(List<FsEntry> files) async {
    final inbox = await _inboxDir();
    final skip = <String>{};
    var skippedBytes = 0;
    for (final f in files) {
      final local = File('${inbox.path}/${sanitizeFilename(f.name)}');
      // 同名且同尺寸才值得算哈希（内容不同必尺寸不同，省去大文件哈希）。
      if (local.existsSync() && await local.length() == f.size) {
        skip.add(await sha256FileHex(local));
        skippedBytes += f.size;
      }
    }
    final totalBytes = files.fold(0, (a, f) => a + f.size) - skippedBytes;
    final task = TransferTask(
      label: t.mlf.packLabel(count: files.length),
      kind: TransferKind.pack,
      totalBytes: totalBytes,
      runner: (task) => _withReauth(() => _runPack(task, files, skip)),
    )..setDetail(t.mlf.packDetail(added: formatBytes(totalBytes), skipped: formatBytes(skippedBytes)));
    _queue.enqueue(task);
  }

  /// 消费打包流：逐帧落盘 + SHA-256 校验（帧自带指纹，落盘后复核）。
  Future<void> _runPack(TransferTask task, List<FsEntry> files, Set<String> skip) async {
    final inbox = await _inboxDir();
    final reader = await _client!.pack(
      _remoteBase!,
      files.map((f) => f.path).toList(),
      skip: skip,
    );
    var received = 0;
    try {
      while (true) {
        _throwIfCanceled(task);
        final frame = await reader.next();
        if (frame == null) {
          break;
        }
        task.setDetail(t.mlf.transferItem(name: frame.name));
        debugPrint('[MLF] frame: ${frame.name} ${frame.size}B');
        final target = File('${inbox.path}/${sanitizeFilename(frame.name)}');
        final sink = target.openWrite();
        var ok = true;
        try {
          await sink.addStream(
            countBytes(frame.data, (d) {
              _throwIfCanceled(task);
              task.addBytes(d);
            }),
          );
          await sink.flush();
        } on Object {
          ok = false;
          rethrow;
        } finally {
          await sink.close();
          if (!ok) {
            await target.delete(); // 半截文件不留在收件箱
          }
        }
        final sha = await sha256FileHex(target);
        if (sha != frame.shaHex) {
          await target.delete();
          throw MlfClientException(t.mlf.verifyFailed(name: frame.name));
        }
        received++;
      }
    } finally {
      // 提前退出（取消/错误）也关闭底层连接，避免泄漏。
      await reader.cancel();
    }
    task.setDetail(t.mlf.packDone(received: received, skipped: files.length - received));
    debugPrint('[MLF] pack done: +$received skipped=${files.length - received}');
  }

  // ---- 上传（PC → 远端 / 手机 → 远端）----

  /// 选本地文件 → 上传到当前浏览目录（远端原子落名 + 断点续传）。
  Future<void> _pickAndUpload() async {
    if (_client == null || _remoteBase == null) {
      return;
    }
    final result = await FilePicker.pickFiles(
      type: FileType.any,
      allowMultiple: true,
    );
    final files = result?.paths.whereType<String>().toList() ?? const [];
    if (files.isEmpty) {
      return;
    }
    _refreshAfterUploads = true;
    for (final path in files) {
      final f = File(path);
      final size = f.existsSync() ? f.lengthSync() : 0;
      _queue.enqueue(
        TransferTask(
          label: '↑ ${f.uri.pathSegments.last}',
          kind: TransferKind.upload,
          totalBytes: size,
          runner: (task) => _withReauth(() => _runUpload(task, f)),
        ),
      );
    }
  }

  Future<void> _runUpload(TransferTask task, File file, [String? targetDir]) async {
    final target = targetDir ?? _currentPath;
    debugPrint('[MLF] upload ${file.path} (${file.lengthSync()}B) -> $target');
    await _client!.upload(
      _remoteBase!,
      file,
      target,
      onProgress: (sent, total) {
        _throwIfCanceled(task);
        final delta = sent - task.receivedBytes;
        if (delta > 0) {
          task.addBytes(delta);
        }
      },
    );
    debugPrint('[MLF] upload done: ${file.uri.pathSegments.last}');
  }

  void _onQueueChanged() {
    if (_refreshAfterUploads && !_queue.isBusy && _client != null && _remoteBase != null) {
      _refreshAfterUploads = false;
      unawaited(
        _openDir(_currentPath).catchError((Object e) {
          debugPrint('[MLF] post-upload refresh failed: $e');
        }),
      );
    }
  }

  /// 相册网格点按：下载原图（复用单文件下载队列/断点）。
  void _downloadMediaEntry(Map<dynamic, dynamic> entry) {
    final path = entry['path'] as String?;
    final name = entry['name'] as String? ?? 'media';
    if (path == null) {
      return;
    }
    final fsEntry = FsEntry.fromMap(entry);
    _queue.enqueue(
      TransferTask(
        label: name,
        kind: TransferKind.singleFile,
        totalBytes: fsEntry.size,
        runner: (task) => _withReauth(() => _runDownload(task, fsEntry)),
      ),
    );
  }

  /// 多选下载入口：按 §4.2 自适应规则选打包流或逐文件。
  Future<void> _downloadSelected() async {
    final files = _entries.where((e) => !e.isDir && _selected.contains(e.path)).toList();
    if (files.isEmpty) {
      return;
    }
    final mode = pickTransferMode(files.map((f) => f.size));
    if (mode == TransferMode.pack) {
      await _enqueuePack(files);
    } else {
      for (final f in files) {
        _enqueueDownload(f);
      }
    }
    setState(() => _selected.clear());
  }

  // ---- UI ----

  @override
  Widget build(BuildContext context) {
    final selectedFiles = _entries.where((e) => !e.isDir && _selected.contains(e.path)).toList();
    if (_busy) {
      return Scaffold(
        appBar: AppBar(title: Text(t.mlf.browseTitle)),
        body: const Center(child: CircularProgressIndicator()),
      );
    }
    if (_photosMode && _remoteBase != null && _client != null) {
      return Scaffold(
        appBar: AppBar(
          title: Text(
            t.mlf.photosWith(name: _servers.where((s) => s.fp == _pinnedFp).map((s) => s.alias).firstOrNull ?? t.mlf.peer),
          ),
        ),
        body: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
              child: Row(
                children: [
                  SegmentedButton<bool>(
                    segments: [
                      ButtonSegment(value: false, label: Text(t.mlf.files), icon: Icon(Icons.folder_outlined)),
                      ButtonSegment(value: true, label: Text(t.mlf.photos), icon: Icon(Icons.photo_library_outlined)),
                    ],
                    selected: const {true},
                    onSelectionChanged: (sel) => setState(() => _photosMode = sel.first),
                  ),
                  const Spacer(),
                  IconButton(
                    icon: const Icon(Icons.refresh),
                    tooltip: t.mlf.refresh,
                    onPressed: () => setState(() {}),
                  ),
                ],
              ),
            ),
            Expanded(
              child: MlfPhotoGrid(
                client: _client!,
                base: _remoteBase!,
                onDownloadOriginal: _downloadMediaEntry,
                key: ValueKey('photos-$_remoteBase'),
              ),
            ),
            const Divider(height: 1),
            SizedBox(
              height: 200,
              child: SingleChildScrollView(child: _buildQueuePanel()),
            ),
          ],
        ),
      );
    }
    return Scaffold(
      appBar: AppBar(title: Text(t.mlf.browseTitle)),
      body: _busy
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(12),
              children: [
                if (Platform.isAndroid && _manageGranted == false) ...[
                  _buildManageCard(),
                  const SizedBox(height: 8),
                ],
                _buildServerCard(),
                const SizedBox(height: 8),
                _buildServerChips(),
                _buildConnectRow(),
                if (_error != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text(
                      _error!,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                  ),
                const Divider(height: 24),
                if (_remoteBase != null) ...[
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: SegmentedButton<bool>(
                        segments: [
                          ButtonSegment(value: false, label: Text(t.mlf.files), icon: Icon(Icons.folder_outlined)),
                          ButtonSegment(value: true, label: Text(t.mlf.photos), icon: Icon(Icons.photo_library_outlined)),
                        ],
                        selected: const {false},
                        onSelectionChanged: (sel) => setState(() => _photosMode = sel.first),
                      ),
                    ),
                  ),
                  _buildSelectionBar(selectedFiles),
                  ..._buildEntryList(),
                ] else
                  Padding(
                    padding: const EdgeInsets.all(16),
                    child: Center(child: Text(t.mlf.emptyBrowseHint)),
                  ),
                const Divider(height: 24),
                _buildQueuePanel(),
              ],
            ),
    );
  }

  Widget _buildServerCard() {
    final running = _server != null;
    return Card(
      child: ListTile(
        leading: Icon(running ? Icons.stop : Icons.play_arrow),
        title: Text(running ? t.mlf.stopServer : t.mlf.startServer),
        subtitle: Text(
          running
              ? t.mlf.serverStatus(
                  path: _rootPath ?? '',
                  url: '$_rootPath\nhttps://${_lanIp ?? '127.0.0.1'}:${_server!.port}',
                  fp: _identity!.fingerprint.substring(0, 12),
                )
              : t.mlf.serverHint,
        ),
        isThreeLine: running,
        onTap: () => unawaited(_toggleServer()),
        trailing: running
            ? IconButton(
                icon: const Icon(Icons.qr_code_2),
                tooltip: t.mlf.qrTooltip,
                onPressed: _showPairingQr,
              )
            : null,
      ),
    );
  }

  /// Android/iOS：相机扫码填入配对信息并连接；桌面端无相机扫码，走粘贴。
  Future<void> _scanAndConnect() async {
    final result = await Navigator.of(context).push<String>(
      MaterialPageRoute(builder: (context) => const MlfQrScanPage()),
    );
    if (result == null || result.isEmpty || !mounted) {
      return;
    }
    _addressController.text = result;
    await _connect();
  }

  Widget _buildServerChips() {
    if (_remoteBase != null) {
      return const SizedBox.shrink();
    }
    // 附近新发现的设备(不在记忆列表中的)优先展示——零操作即连。
    final knownFps = _servers.map((s) => s.fp).toSet();
    final fresh = _discovered.where((d) => !knownFps.contains(d.fingerprint)).toList();
    if (fresh.isNotEmpty) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Text(
              t.mlf.nearbyDevices,
              style: Theme.of(context).textTheme.labelMedium?.copyWith(
                color: Theme.of(context).colorScheme.primary,
              ),
            ),
          ),
          SizedBox(
            height: 40,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: fresh.length,
              separatorBuilder: (_, _) => const SizedBox(width: 8),
              itemBuilder: (context, i) {
                final d = fresh[i];
                return ActionChip(
                  avatar: const Icon(Icons.wifi_tethering, size: 18),
                  label: Text(d.alias.isEmpty ? d.ip : d.alias),
                  onPressed: () {
                    debugPrint('[MLF] connect to discovered: ' + d.alias + ' @' + d.ip);
                    _addressController.text = d.pairingJson;
                    unawaited(_connect());
                  },
                );
              },
            ),
          ),
          if (_servers.isNotEmpty) const SizedBox(height: 4),
        ],
      );
    }
    if (_servers.isEmpty) {
      return const SizedBox.shrink();
    }
    return SizedBox(
      height: 44,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: _servers.length,
        separatorBuilder: (_, _) => const SizedBox(width: 8),
        itemBuilder: (context, i) {
          final s = _servers[i];
          return ActionChip(
            avatar: Icon(
              s.fp == _servers.first.fp && i == 0 ? Icons.history : Icons.devices_other,
              size: 18,
            ),
            label: Text(s.alias.isEmpty ? s.ip : s.alias),
            onPressed: () {
              _addressController.text = s.pairingJson;
              unawaited(_connect());
            },
          );
        },
      ),
    );
  }

  Widget _buildConnectRow() {
    final canScan = Platform.isAndroid || Platform.isIOS;
    return Column(
      children: [
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: _addressController,
                decoration: InputDecoration(
                  labelText: t.mlf.pairingInfoLabel,
                  hintText: '{"v":1,"proto":"mlf",...}',
                ),
              ),
            ),
            if (canScan) ...[
              const SizedBox(width: 8),
              IconButton(
                icon: const Icon(Icons.qr_code_scanner),
                tooltip: t.mlf.scanTooltip,
                onPressed: () => unawaited(_scanAndConnect()),
              ),
            ],
            const SizedBox(width: 8),
            FilledButton(onPressed: _connect, child: Text(t.mlf.connect)),
          ],
        ),
        if (_server != null)
          Align(
            alignment: Alignment.centerRight,
            child: TextButton.icon(
              onPressed: _connectLocalDemo,
              icon: const Icon(Icons.loop),
              label: Text(t.mlf.localDemo),
            ),
          ),
      ],
    );
  }

  /// Android 未授「所有文件访问」时的引导卡（§4.1 浏览整个存储的前提）。
  Widget _buildManageCard() {
    return Card(
      color: Theme.of(context).colorScheme.secondaryContainer,
      child: ListTile(
        leading: const Icon(Icons.folder_special),
        title: Text(t.mlf.grantAllFilesTitle),
        subtitle: Text(t.mlf.grantAllFilesBody),
        isThreeLine: true,
        trailing: FilledButton(
          onPressed: () => unawaited(_requestManage()),
          child: Text(t.mlf.grant),
        ),
      ),
    );
  }

  Widget _buildSelectionBar(List<FsEntry> selectedFiles) {
    final dirCount = _entries.where((e) => e.isDir).length;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            TextButton(
              onPressed: () => setState(() {
                if (_selected.length < _entries.length - dirCount) {
                  _selected
                    ..clear()
                    ..addAll(_entries.where((e) => !e.isDir).map((e) => e.path));
                } else {
                  _selected.clear();
                }
              }),
              child: Text(
                _selected.isEmpty || _selected.length < _entries.length - dirCount ? t.mlf.selectAll : t.mlf.deselectAll,
              ),
            ),
            const Spacer(),
            if (selectedFiles.isNotEmpty)
              Text(
                t.mlf.selectedCount(
                  count: selectedFiles.length,
                  size: formatBytes(selectedFiles.fold(0, (a, f) => a + f.size)),
                  mode: pickTransferMode(selectedFiles.map((f) => f.size)) == TransferMode.pack ? t.mlf.packStream : t.mlf.fileByFile,
                ),
              ),
          ],
        ),
        if (selectedFiles.isNotEmpty)
          FilledButton.icon(
            onPressed: _downloadSelected,
            icon: const Icon(Icons.download),
            label: Text(t.mlf.downloadSelected),
          )
        else
          FilledButton.tonalIcon(
            onPressed: () => unawaited(_pickAndUpload()),
            icon: const Icon(Icons.upload_file),
            label: Text(_currentPath == '/' ? t.mlf.uploadToRoot : t.mlf.uploadToCurrent),
          ),
      ],
    );
  }

  List<Widget> _buildEntryList() {
    final widgets = <Widget>[];
    if (_currentPath != '/') {
      widgets.add(
        ListTile(
          leading: const Icon(Icons.arrow_upward),
          title: const Text('..'),
          onTap: () {
            final parent = _currentPath.endsWith('/') ? _currentPath.substring(0, _currentPath.length - 1) : _currentPath;
            final idx = parent.lastIndexOf('/');
            unawaited(_openDir(idx <= 0 ? '/' : parent.substring(0, idx)));
          },
        ),
      );
    }
    for (final e in _entries) {
      widgets.add(
        ListTile(
          leading: e.isDir
              ? const Icon(Icons.folder)
              : Checkbox(
                  value: _selected.contains(e.path),
                  onChanged: (_) => _toggleSelect(e),
                ),
          title: Text(e.name),
          subtitle: Text(e.isDir ? t.mlf.dirLabel : formatBytes(e.size)),
          onTap: () => _openEntry(e),
          trailing: e.isDir
              ? null
              : IconButton(
                  icon: const Icon(Icons.download),
                  tooltip: t.mlf.downloadTooltip,
                  onPressed: () => _enqueueDownload(e),
                ),
        ),
      );
    }
    return widgets;
  }

  Future<void> _openDir(String path) async {
    setState(() => _busy = true);
    try {
      await _listDir(path);
    } on Object catch (e) {
      setState(() => _error = '$e');
    } finally {
      setState(() => _busy = false);
    }
  }

  void _toggleSelect(FsEntry e) {
    setState(() {
      if (!_selected.add(e.path)) {
        _selected.remove(e.path);
      }
    });
  }

  Widget _buildQueuePanel() {
    return ListenableBuilder(
      listenable: _queue,
      builder: (context, _) {
        final tasks = _queue.tasks;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                const Icon(Icons.swap_vert, size: 18),
                const SizedBox(width: 4),
                Flexible(
                  child: Text(
                    t.mlf.queueTitle(active: _queue.activeCount, total: tasks.length),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                const Spacer(),
                if (tasks.any(
                  (t) => t.state == TransferState.done || t.state == TransferState.failed || t.state == TransferState.canceled,
                ))
                  TextButton(
                    onPressed: _queue.clearFinished,
                    child: Text(t.mlf.clearDone),
                  ),
              ],
            ),
            if (tasks.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Text(t.mlf.noTasks, style: const TextStyle(color: Colors.grey)),
              ),
            ...tasks.map(_buildTaskTile),
          ],
        );
      },
    );
  }

  Widget _buildTaskTile(TransferTask task) {
    return ListenableBuilder(
      listenable: task,
      builder: (context, _) {
        final failed = task.state == TransferState.failed;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  switch (task.state) {
                    TransferState.queued => Icons.schedule,
                    TransferState.running => Icons.sync,
                    TransferState.done => Icons.check_circle,
                    TransferState.failed => Icons.error,
                    TransferState.canceled => Icons.cancel_outlined,
                  },
                  size: 18,
                  color: switch (task.state) {
                    TransferState.done => Colors.green,
                    TransferState.failed => Theme.of(context).colorScheme.error,
                    TransferState.canceled => Colors.orange,
                    _ => Colors.grey,
                  },
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    task.label,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                Text(
                  '${formatBytes(task.receivedBytes)} / ${formatBytes(task.totalBytes)}',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                if (task.state == TransferState.running || task.state == TransferState.queued)
                  IconButton(
                    icon: const Icon(Icons.close, size: 18),
                    tooltip: t.mlf.cancelKeepBreakpoint,
                    onPressed: () => task.cancel(),
                  ),
                if (failed || task.state == TransferState.canceled)
                  IconButton(
                    icon: const Icon(Icons.refresh, size: 18),
                    tooltip: t.mlf.retryResume,
                    onPressed: () => _queue.retry(task),
                  ),
              ],
            ),
            if (task.detail.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(left: 24),
                child: Text(
                  failed ? '${task.detail} ${task.error ?? ''}' : task.detail,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: failed ? Theme.of(context).colorScheme.error : null,
                  ),
                ),
              ),
            LinearProgressIndicator(
              value: task.state == TransferState.done ? 1 : task.progress,
            ),
            const SizedBox(height: 8),
          ],
        );
      },
    );
  }
}

class _RememberedServer {
  _RememberedServer({
    required this.alias,
    required this.ip,
    required this.port,
    required this.fp,
    required this.lastUsedMs,
  });

  factory _RememberedServer.fromMap(Map<dynamic, dynamic> m) => _RememberedServer(
    alias: m['alias'] as String? ?? '',
    ip: m['ip'] as String,
    port: (m['port'] as num).toInt(),
    fp: m['fp'] as String,
    lastUsedMs: (m['lastUsed'] as num?)?.toInt() ?? 0,
  );

  final String alias;
  final String ip;
  final int port;
  final String fp;
  final int lastUsedMs;

  Map<String, Object?> toMap() => {'alias': alias, 'ip': ip, 'port': port, 'fp': fp, 'lastUsed': lastUsedMs};

  String get pairingJson => jsonEncode({
    'v': 1,
    'proto': 'mlf',
    'ip': ip,
    'port': port,
    'fp': fp,
  });
}

String formatBytes(int bytes) {
  if (bytes < 1024) {
    return '$bytes B';
  }
  if (bytes < 1024 * 1024) {
    return '${(bytes / 1024).toStringAsFixed(1)} KB';
  }
  if (bytes < 1024 * 1024 * 1024) {
    return '${(bytes / 1024).toStringAsFixed(1)} MB';
  }
  return '${(bytes / 1024 / 1024 / 1024).toStringAsFixed(2)} GB';
}
