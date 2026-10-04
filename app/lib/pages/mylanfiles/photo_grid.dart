import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:mylanfiles_core/mylanfiles_core.dart';
import 'package:mylanfiles_server/mylanfiles_server.dart';

/// 相册网格视图（§4.1 media/list + /thumb 消费方）。
///
/// 桶 chips（DCIM/Pictures/…）→ 缩略图网格（token 取图，页内 LRU 内存缓存）
/// → 点按下载原图（走浏览页既有的下载队列/断点）。
class MlfPhotoGrid extends StatefulWidget {
  const MlfPhotoGrid({
    required this.client,
    required this.base,
    required this.onDownloadOriginal,
    super.key,
  });

  final MlfClient client;
  final Uri base;

  /// 点按条目：下载原图（由浏览页入队，复用队列/断点/进度）。
  final void Function(Map<dynamic, dynamic> entry) onDownloadOriginal;

  @override
  State<MlfPhotoGrid> createState() => _MlfPhotoGridState();
}

class _MlfPhotoGridState extends State<MlfPhotoGrid> {
  List<Map<dynamic, dynamic>> _buckets = [];
  String? _bucket;
  List<Map<dynamic, dynamic>> _entries = [];
  bool _loading = false;
  String? _error;

  /// token → 缩略图字节（会话内缓存;HTTP 层还有服务端磁盘缓存）。
  final Map<String, Uint8List> _thumbCache = {};
  final Map<String, Future<Uint8List?>> _thumbInFlight = {};

  @override
  void initState() {
    super.initState();
    _loadBuckets();
  }

  Future<void> _loadBuckets() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final res = await widget.client.getJson(widget.base, 'media/list');
      final buckets = (res['buckets'] as List).map((b) => (b as Map).cast<String, dynamic>()).toList();
      setState(() {
        _buckets = buckets;
        _loading = false;
      });
      if (buckets.isNotEmpty) {
        await _openBucket(buckets.first['name'] as String);
      }
    } on Object catch (e) {
      setState(() {
        _error = '相册加载失败: $e';
        _loading = false;
      });
    }
  }

  Future<void> _openBucket(String name) async {
    setState(() {
      _bucket = name;
      _loading = true;
      _error = null;
    });
    try {
      final res = await widget.client.getJson(
        widget.base,
        'media/list?bucket=$name&limit=500',
      );
      setState(() {
        _entries = (res['entries'] as List).map((e) => (e as Map).cast<String, dynamic>()).toList();
        _loading = false;
      });
      unawaited(_prefetchAll());
    } on Object catch (e) {
      setState(() {
        _error = '桶加载失败: $e';
        _loading = false;
      });
    }
  }

  /// 首屏之后后台预取整页缩略图(2 并发),滚动到哪都即时可见。
  Future<void> _prefetchAll() async {
    final tokens = _entries.map((e) => e['thumb'] as String?).whereType<String>().toList();
    debugPrint('[MLF] thumb prefetch start: ' + tokens.length.toString());
    final it = tokens.iterator;
    Future<void> worker() async {
      while (it.moveNext()) {
        await _thumb(it.current);
      }
    }

    await Future.wait([worker(), worker()]);
    debugPrint('[MLF] thumb prefetch done');
  }

  Future<Uint8List?> _thumb(String token) {
    return _thumbInFlight.putIfAbsent(token, () async {
      final hit = _thumbCache[token];
      if (hit != null) {
        return hit;
      }
      try {
        final bytes = await widget.client.thumb(widget.base, token, size: 320);
        if (_thumbCache.length > 300) {
          _thumbCache.clear(); // 粗粒度上限,防大相册内存
        }
        _thumbCache[token] = bytes;
        debugPrint('[MLF] ' + DateTime.now().toIso8601String().substring(11, 19) + ' thumb fetched, cache=' + _thumbCache.length.toString());
        return bytes;
      } on Object {
        return null; // HEIC 等不支持 → 占位
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(
          height: 44,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            itemCount: _buckets.length,
            separatorBuilder: (_, _) => const SizedBox(width: 8),
            itemBuilder: (context, i) {
              final b = _buckets[i]['name'] as String;
              return ChoiceChip(
                label: Text(b),
                selected: _bucket == b,
                onSelected: (_) => _openBucket(b),
              );
            },
          ),
        ),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.all(8),
            child: Text(
              _error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ),
        if (_loading) const LinearProgressIndicator(minHeight: 2),
        Expanded(
          child: _entries.isEmpty && !_loading
              ? const Center(child: Text('该桶没有媒体文件'))
              : GridView.builder(
                  gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 3,
                    mainAxisSpacing: 2,
                    crossAxisSpacing: 2,
                  ),
                  itemCount: _entries.length,
                  itemBuilder: (context, i) {
                    final e = _entries[i];
                    final token = e['thumb'] as String?;
                    return GestureDetector(
                      onTap: () => widget.onDownloadOriginal(e),
                      child: GridTile(
                        child: Container(
                          color: Colors.black12,
                          child: token == null
                              ? const Icon(Icons.videocam_outlined)
                              : FutureBuilder<Uint8List?>(
                                  future: _thumb(token),
                                  builder: (context, snap) {
                                    if (snap.hasData) {
                                      return Image.memory(
                                        snap.data!,
                                        fit: BoxFit.cover,
                                        gaplessPlayback: true,
                                      );
                                    }
                                    if (snap.hasError) {
                                      return const Icon(Icons.broken_image);
                                    }
                                    return const Center(
                                      child: SizedBox(
                                        width: 20,
                                        height: 20,
                                        child: CircularProgressIndicator(
                                          strokeWidth: 2,
                                        ),
                                      ),
                                    );
                                  },
                                ),
                        ),
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }
}

// FsEntry 引用仅在类型文档语境出现;避免误报未使用。
// ignore: unused_element
final _fsEntryRef = FsEntry;
