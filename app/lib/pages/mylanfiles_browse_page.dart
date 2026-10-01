import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:mylanfiles_core/mylanfiles_core.dart';
import 'package:mylanfiles_server/mylanfiles_server.dart';
import 'package:path_provider/path_provider.dart';

/// MyLanFiles 浏览页（P1 垂直切片 2）：
/// - 「本机服务」：以下载目录为共享根起 MlfServer（loopback，开发期 http）
/// - 「连接远程」：配对（开发期自动指纹）→ 列目录 → 逐级浏览 → 点文件下载到收件箱
///
/// 有意不依赖上游 provider/i18n（fork 卫生）；真实二维码配对与 TLS 在后续切片接入。
class MyLanFilesBrowsePage extends StatefulWidget {
  const MyLanFilesBrowsePage({super.key});

  @override
  State<MyLanFilesBrowsePage> createState() => _MyLanFilesBrowsePageState();
}

class _MyLanFilesBrowsePageState extends State<MyLanFilesBrowsePage> {
  MlfServer? _server;
  String? _serverFingerprint;
  String? _rootPath;

  final _addressController = TextEditingController();
  final _client = http.Client();
  String? _clientFingerprint;

  List<FsEntry> _entries = [];
  String _currentPath = '/';
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    unawaited(_server?.stop());
    _client.close();
    _addressController.dispose();
    super.dispose();
  }

  Future<Directory> _inboxDir() async {
    final base = await getDownloadsDirectory() ?? await getApplicationDocumentsDirectory();
    final inbox = Directory('${base.path}/MyLanFiles-Inbox');
    if (!inbox.existsSync()) {
      inbox.createSync(recursive: true);
    }
    return inbox;
  }

  Future<void> _toggleServer() async {
    setState(() => _busy = true);
    try {
      if (_server != null) {
        await _server!.stop();
        _server = null;
        _serverFingerprint = null;
      } else {
        final inbox = await _inboxDir();
        _rootPath = inbox.parent.path; // 共享根演示用收件箱所在目录
        _server = MlfServer(
          vfs: LocalVfs(root: _rootPath!),
          serverFingerprint: devFingerprint('local-server'),
        );
        await _server!.bind(InternetAddress.loopbackIPv4, 0);
        _serverFingerprint = devFingerprint('local-server');
        _addressController.text = 'http://127.0.0.1:${_server!.port}';
      }
      setState(() {});
    } on Object catch (e) {
      setState(() => _error = '服务启动失败: $e');
    } finally {
      setState(() => _busy = false);
    }
  }

  Map<String, String> get _authHeaders => _clientFingerprint == null ? {} : {'x-mlf-fingerprint': _clientFingerprint!};

  Future<void> _connect() async {
    final raw = _addressController.text.trim();
    if (raw.isEmpty) {
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final base = Uri.parse(raw.endsWith('/') ? raw : '$raw/');
      _clientFingerprint ??= devFingerprint('client');

      final pairRes = await _client.post(
        base.resolve('api/v1/pair'),
        body: '{"fingerprint":"$_clientFingerprint"}',
        headers: {'content-type': 'application/json'},
      );
      if (pairRes.statusCode != 200) {
        throw '配对失败: ${pairRes.statusCode} ${pairRes.body}';
      }
      await _listDir(base, '/');
      setState(() {});
    } on Object catch (e) {
      setState(() => _error = '$e');
    } finally {
      setState(() => _busy = false);
    }
  }

  Future<void> _listDir(Uri base, String path) async {
    final res = await _client.get(
      base.resolve('api/v1/fs/list').replace(queryParameters: {'path': path}),
      headers: _authHeaders,
    );
    if (res.statusCode != 200) {
      throw '列目录失败: ${res.statusCode} ${res.body}';
    }
    final body = jsonDecodeMap(res.body);
    final entries = (body['entries'] as List).map((m) => FsEntry.fromMap(m as Map<dynamic, dynamic>)).toList();
    setState(() {
      _entries = entries;
      _currentPath = body['path'] as String? ?? path;
    });
  }

  Future<void> _download(FsEntry entry) async {
    if (_addressController.text.isEmpty) {
      return;
    }
    final base = Uri.parse(_addressController.text);
    setState(() => _busy = true);
    try {
      final res = await _client.get(
        base.resolve('api/v1/fs/read').replace(queryParameters: {'path': entry.path}),
        headers: _authHeaders,
      );
      if (res.statusCode != 200) {
        throw '下载失败: ${res.statusCode}';
      }
      final inbox = await _inboxDir();
      final safeName = sanitizeFilename(entry.name);
      final target = File('${inbox.path}/$safeName');
      if (target.existsSync()) {
        target.deleteSync();
      }
      await target.writeAsBytes(res.bodyBytes, flush: true);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('已下载到 ${target.path}')),
        );
      }
    } on Object catch (e) {
      setState(() => _error = '$e');
    } finally {
      setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final remoteBase = _addressController.text.trim().isEmpty ? null : Uri.parse(_addressController.text.trim());
    return Scaffold(
      appBar: AppBar(title: const Text('MyLanFiles 浏览')),
      body: _busy
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(12),
              children: [
                Card(
                  child: ListTile(
                    leading: Icon(
                      _server == null ? Icons.play_arrow : Icons.stop,
                    ),
                    title: Text(_server == null ? '启动本机服务' : '停止本机服务'),
                    subtitle: Text(
                      _server == null ? '共享根：本机收件箱目录' : '$_rootPath\n端口 ${_server!.port} · 指纹 ${_serverFingerprint?.substring(0, 12)}…',
                    ),
                    isThreeLine: _server != null,
                    onTap: () async => await _toggleServer(),
                  ),
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _addressController,
                        decoration: const InputDecoration(
                          labelText: '远程地址',
                          hintText: 'http://127.0.0.1:端口',
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    FilledButton(
                      onPressed: _connect,
                      child: const Text('连接'),
                    ),
                  ],
                ),
                if (_error != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text(
                      _error!,
                      style: TextStyle(color: Theme.of(context).colorScheme.error),
                    ),
                  ),
                const Divider(height: 24),
                if (_entries.isNotEmpty) ...[
                  if (_currentPath != '/')
                    ListTile(
                      leading: const Icon(Icons.arrow_upward),
                      title: const Text('..'),
                      onTap: () async {
                        final parent = _currentPath.endsWith('/') ? _currentPath.substring(0, _currentPath.length - 1) : _currentPath;
                        final idx = parent.lastIndexOf('/');
                        await _listDir(remoteBase!, idx <= 0 ? '/' : parent.substring(0, idx));
                      },
                    ),
                  ..._entries.map(
                    (e) => ListTile(
                      leading: Icon(e.isDir ? Icons.folder : Icons.insert_drive_file),
                      title: Text(e.name),
                      subtitle: Text(e.isDir ? '目录' : formatBytes(e.size)),
                      onTap: () async {
                        if (e.isDir) {
                          await _listDir(remoteBase!, e.path);
                        } else {
                          await _download(e);
                        }
                      },
                    ),
                  ),
                ] else
                  const Padding(
                    padding: EdgeInsets.all(16),
                    child: Center(child: Text('连接远程后在此浏览文件')),
                  ),
              ],
            ),
    );
  }
}

// ---- 小工具（避免为此引依赖）----

Map<dynamic, dynamic> jsonDecodeMap(String source) => const JsonDecoder().convert(source) as Map<dynamic, dynamic>;

String formatBytes(int bytes) {
  if (bytes < 1024) {
    return '$bytes B';
  }
  if (bytes < 1024 * 1024) {
    return '${(bytes / 1024).toStringAsFixed(1)} KB';
  }
  if (bytes < 1024 * 1024 * 1024) {
    return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
  }
  return '${(bytes / 1024 / 1024 / 1024).toStringAsFixed(2)} GB';
}
