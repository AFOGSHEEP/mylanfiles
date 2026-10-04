import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:localsend_app/pages/mylanfiles/qr_scan_page.dart';
import 'package:localsend_app/pages/mylanfiles/transfer_queue.dart';
import 'package:mylanfiles_core/mylanfiles_core.dart';
import 'package:mylanfiles_server/mylanfiles_server.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:pretty_qr_code/pretty_qr_code.dart';

/// MyLanFiles 浏览页（P1 垂直切片 3）：
/// - 「本机服务」：持久化自签 TLS 身份 + LAN 地址 + 二维码配对（§4.1 pair）
/// - 「连接远程」：粘贴二维码内容（JSON）→ 指纹 pin 握手 → 配对 → 浏览
/// - 「传输」：多选 → 自适应打包流（§4.2 中位 <2MiB）/ 逐文件 Range 续传，
///   队列串行执行 + 进度 UI；skip 断点续传（内容寻址，重传只补缺）
///
/// 有意不依赖上游 provider/i18n（fork 卫生，ADR-0002）；QR 用上游同一
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
      // 桌面联调捷径：MLF_PAIR_FILE 指向配对 JSON → 自动连接（反向场景用）。
      final pairFile = Platform.environment['MLF_PAIR_FILE'];
      if (pairFile != null && pairFile.isNotEmpty) {
        WidgetsBinding.instance.addPostFrameCallback((_) async {
          try {
            final raw = (await File(pairFile).readAsString()).trim();
            debugPrint('[MLF] pair-file loaded (${raw.length} chars)');
            _addressController.text = raw;
            await _connect();
          } on Object catch (e) {
            debugPrint('[MLF] pair-file error: $e');
          }
        });
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
    } on Object catch (e) {
      debugPrint('[MLF] auto-download error: $e');
    }
  }

  Future<void> _autoStartForE2E() async {
    if (_server != null) {
      return;
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

  // ---- 本机服务（TLS + QR 配对）----

  Future<void> _toggleServer() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      if (_server != null) {
        await _server!.stop();
        _server = null;
        setState(() {});
        return;
      }
      // 身份持久化在应用私有目录（共享根之外，私钥不可经共享根泄露）。
      final support = await getApplicationSupportDirectory();
      _identity = await loadOrCreateIdentity(
        Directory('${support.path}/identity'),
      );
      _rootPath = await _sharedRoot();
      final server = MlfServer(
        vfs: LocalVfs(root: _rootPath!),
        serverFingerprint: _identity!.fingerprint,
      );
      await server.bind(
        InternetAddress.anyIPv4,
        0,
        securityContext: _identity!.context,
      );
      _server = server;
      _lanIp = await lanIPv4();
      setState(() {});
    } on Object catch (e) {
      setState(() => _error = '服务启动失败: $e');
    } finally {
      setState(() => _busy = false);
    }
  }

  MlfPairingInfo pairingInfoOf(String ip) => MlfPairingInfo(
    ip: ip,
    port: _server?.port ?? 0,
    fingerprint: _identity?.fingerprint ?? '',
  );

  Future<void> _showPairingQr() async {
    final info = pairingInfoOf(_lanIp ?? '127.0.0.1');
    final json = const JsonEncoder.withIndent(' ').convert(info.toJson());
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('扫码 / 粘贴配对'),
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
                '指纹 ${info.fingerprint.substring(0, 16)}…',
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
                ).showSnackBar(const SnackBar(content: Text('配对信息已复制')));
              }
            },
            child: const Text('复制配对信息'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
  }

  // ---- 远程连接（指纹 pin 握手）----

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
      setState(() => _error = '配对信息格式错误: $e');
      return;
    }
    if (!info.hasFingerprint) {
      setState(() => _error = '缺少证书指纹——请粘贴完整二维码内容（JSON）');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    _client?.close();
    _client = null;
    try {
      final client = MlfClient(pinnedFingerprint: info.fingerprint);
      // 握手即校验：证书指纹 ≠ 二维码指纹时 TLS 握手直接失败（§7 pin）。
      await client.pair(info.baseUri, _clientFingerprint);
      _client = client;
      _remoteBase = info.baseUri;
      debugPrint('[MLF] pair ok -> ${info.baseUri}');
      await _listDir('/');
      setState(() {});
    } on Object catch (e) {
      debugPrint('[MLF] connect FAILED: $e');
      _remoteBase = null;
      setState(() => _error = '连接失败（指纹不匹配或不可达）: $e');
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

  /// 逐文件下载，Range 断点续传：`.part` 落盘，失败保留，重试从
  /// offset=part 长度继续（§4.1 fs/read offset）。成功后原子改名。
  /// 远端文件比本地 .part 小（远端已变化）时丢弃 .part 从头重传。
  Future<void> _runDownload(TransferTask task, FsEntry entry) async {
    final inbox = await _inboxDir();
    final safeName = sanitizeFilename(entry.name);
    final part = File('${inbox.path}/$safeName.part');
    var offset = part.existsSync() ? await part.length() : 0;
    debugPrint('[MLF] download ${entry.name} @offset=$offset size=${entry.size}');
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
      task.setDetail('断点续传：从 ${formatBytes(offset)} 处继续');
      task.receivedBytes = offset;
    }
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
        task.setDetail('远端文件已变化，重新下载');
        return _runDownload(task, entry);
      }
      rethrow;
    }
    await _finalizePart(part, File('${inbox.path}/$safeName'));
    debugPrint('[MLF] download done: $safeName');
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
      label: '打包 ${files.length} 个文件',
      kind: TransferKind.pack,
      totalBytes: totalBytes,
      runner: (task) => _withReauth(() => _runPack(task, files, skip)),
    )..setDetail('新增 ${formatBytes(totalBytes)} · 已有跳过 ${formatBytes(skippedBytes)}');
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
        task.setDetail('正在 ${frame.name}');
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
          throw MlfClientException('${frame.name} 校验失败（传输损坏）');
        }
        received++;
      }
    } finally {
      // 提前退出（取消/错误）也关闭底层连接，避免泄漏。
      await reader.cancel();
    }
    task.setDetail('新增 $received 个 · 跳过 ${files.length - received} 个已存在');
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

  Future<void> _runUpload(TransferTask task, File file) async {
    debugPrint('[MLF] upload ${file.path} (${file.lengthSync()}B) -> $_currentPath');
    await _client!.upload(
      _remoteBase!,
      file,
      _currentPath,
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
    return Scaffold(
      appBar: AppBar(title: const Text('MyLanFiles 浏览')),
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
                  _buildSelectionBar(selectedFiles),
                  ..._buildEntryList(),
                ] else
                  const Padding(
                    padding: EdgeInsets.all(16),
                    child: Center(child: Text('连接远程后在此浏览文件')),
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
        title: Text(running ? '停止本机服务' : '启动本机服务（https）'),
        subtitle: Text(
          running
              ? '$_rootPath\nhttps://${_lanIp ?? '127.0.0.1'}:${_server!.port} · '
                    '指纹 ${_identity!.fingerprint.substring(0, 12)}…'
              : '共享根：本机收件箱所在目录；自签证书 + 二维码配对',
        ),
        isThreeLine: running,
        onTap: () => unawaited(_toggleServer()),
        trailing: running
            ? IconButton(
                icon: const Icon(Icons.qr_code_2),
                tooltip: '配对二维码',
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

  Widget _buildConnectRow() {
    final canScan = Platform.isAndroid || Platform.isIOS;
    return Column(
      children: [
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: _addressController,
                decoration: const InputDecoration(
                  labelText: '配对信息（粘贴或扫码）',
                  hintText: '{"v":1,"proto":"mlf",...}',
                ),
              ),
            ),
            if (canScan) ...[
              const SizedBox(width: 8),
              IconButton(
                icon: const Icon(Icons.qr_code_scanner),
                tooltip: '扫码配对',
                onPressed: () => unawaited(_scanAndConnect()),
              ),
            ],
            const SizedBox(width: 8),
            FilledButton(onPressed: _connect, child: const Text('连接')),
          ],
        ),
        if (_server != null)
          Align(
            alignment: Alignment.centerRight,
            child: TextButton.icon(
              onPressed: _connectLocalDemo,
              icon: const Icon(Icons.loop),
              label: const Text('本机演示（连自己）'),
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
        title: const Text('授予「所有文件访问」以共享手机存储'),
        subtitle: const Text(
          '未授予时：共享根与收件箱降级为应用私有目录。\n'
          '系统设置 → 所有文件访问 → 允许 MyLanFiles',
        ),
        isThreeLine: true,
        trailing: FilledButton(
          onPressed: () => unawaited(_requestManage()),
          child: const Text('去授予'),
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
                _selected.isEmpty || _selected.length < _entries.length - dirCount ? '全选' : '取消全选',
              ),
            ),
            const Spacer(),
            if (selectedFiles.isNotEmpty)
              Text(
                '已选 ${selectedFiles.length} 个 · '
                '${formatBytes(selectedFiles.fold(0, (a, f) => a + f.size))} · '
                '${pickTransferMode(selectedFiles.map((f) => f.size)) == TransferMode.pack ? '打包流' : '逐文件'}',
              ),
          ],
        ),
        if (selectedFiles.isNotEmpty)
          FilledButton.icon(
            onPressed: _downloadSelected,
            icon: const Icon(Icons.download),
            label: const Text('下载所选'),
          )
        else
          FilledButton.tonalIcon(
            onPressed: () => unawaited(_pickAndUpload()),
            icon: const Icon(Icons.upload_file),
            label: Text('上传到 ${_currentPath == '/' ? '根目录' : '当前目录'}'),
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
          subtitle: Text(e.isDir ? '目录' : formatBytes(e.size)),
          onTap: () => _openEntry(e),
          trailing: e.isDir
              ? null
              : IconButton(
                  icon: const Icon(Icons.download),
                  tooltip: '下载',
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
                Text('传输队列（${_queue.activeCount} 活跃 / ${tasks.length} 总计）'),
                const Spacer(),
                if (tasks.any(
                  (t) => t.state == TransferState.done || t.state == TransferState.failed || t.state == TransferState.canceled,
                ))
                  TextButton(
                    onPressed: _queue.clearFinished,
                    child: const Text('清除已完成'),
                  ),
              ],
            ),
            if (tasks.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 8),
                child: Text('暂无传输任务', style: TextStyle(color: Colors.grey)),
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
                    tooltip: '取消（保留断点）',
                    onPressed: () => task.cancel(),
                  ),
                if (failed || task.state == TransferState.canceled)
                  IconButton(
                    icon: const Icon(Icons.refresh, size: 18),
                    tooltip: '重试（断点续传）',
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
