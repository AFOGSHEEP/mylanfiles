import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
import 'package:mylanfiles_core/mylanfiles_core.dart';

import 'tls_context.dart';

const _fingerprintHeader = 'x-mlf-fingerprint';

/// Payload encoded in the pairing QR (交接文档 §4.1): server address plus the
/// certificate fingerprint the client must pin before the first handshake.
class MlfPairingInfo {
  const MlfPairingInfo({
    required this.ip,
    required this.port,
    required this.fingerprint,
    this.alias,
  });

  factory MlfPairingInfo.fromJson(Map<dynamic, dynamic> json) => MlfPairingInfo(
    ip: json['ip'] as String,
    port: (json['port'] as num).toInt(),
    fingerprint: (json['fp'] as String).toLowerCase(),
    alias: json['al'] as String?,
  );

  /// Accepts either the QR JSON or a bare `https://host:port` URL (fingerprint
  /// must then be confirmed out of band — dev convenience).
  factory MlfPairingInfo.parse(String raw) {
    final text = raw.trim();
    if (text.startsWith('{')) {
      return MlfPairingInfo.fromJson(
        const JsonDecoder().convert(text) as Map<dynamic, dynamic>,
      );
    }
    final uri = Uri.parse(text);
    if (uri.host.isEmpty || uri.port == 0) {
      throw FormatException('not a pairing QR or URL: $raw');
    }
    return MlfPairingInfo(
      ip: uri.host,
      port: uri.port,
      fingerprint: '',
      alias: null,
    );
  }

  final String ip;
  final int port;

  /// Server certificate fingerprint (SHA-256 hex, 64 chars). Empty when the
  /// info came from a bare URL.
  final String fingerprint;

  /// Human-facing device name (hostname / model); absent in bare URLs.
  final String? alias;

  Map<String, Object?> toJson() => {
    'v': 1,
    'proto': 'mlf',
    'ip': ip,
    'port': port,
    'fp': fingerprint,
    if (alias != null && alias!.isNotEmpty) 'al': alias,
  };

  Uri get baseUri => Uri.parse('https://$ip:$port/');

  bool get hasFingerprint => fingerprint.length == 64;
}

class MlfClientException implements Exception {
  MlfClientException(this.message);

  final String message;

  @override
  String toString() => 'MlfClientException: $message';
}

/// Protocol peer of [MlfServer] (对等 server+client, 交接文档 §4).
///
/// TLS trust is by pinning: the client knows the server certificate
/// fingerprint from the pairing QR and accepts a handshake only when
/// `sha256(cert.der)` matches — no CA, self-signed is fine (§7).
class MlfClient {
  MlfClient({required String pinnedFingerprint, http.Client? inner})
    : pinnedFingerprint = pinnedFingerprint.toLowerCase(),
      _inner = inner ?? _makePinnedClient(pinnedFingerprint.toLowerCase()) {
    if (pinnedFingerprint.isEmpty) {
      throw ArgumentError('pinnedFingerprint is required (QR pinning)');
    }
  }

  /// The server fingerprint this client trusts (from the QR).
  final String pinnedFingerprint;

  http.Client _inner;
  String? _clientFingerprint;

  static http.Client _makePinnedClient(String pinned) => IOClient(
    HttpClient()
      ..badCertificateCallback = (cert, host, port) {
        return fingerprintOfDer(cert.der) == pinned;
      },
  );

  Map<String, String> get _authHeaders => {
    if (_clientFingerprint != null) _fingerprintHeader: _clientFingerprint!,
  };

  Uri resolve(Uri base, String endpoint) => base.resolve('api/v1/$endpoint');

  /// Exchanges fingerprints (§4.1 pair). Throws when the server's presented
  /// fingerprint differs from [pinnedFingerprint] — QR and handshake must agree.
  Future<String> pair(Uri base, String clientFingerprint) async {
    final res = await _inner.post(
      resolve(base, 'pair'),
      body: jsonEncode({'fingerprint': clientFingerprint}),
      headers: {'content-type': 'application/json'},
    );
    if (res.statusCode != 200) {
      throw MlfClientException('pair failed: ${res.statusCode} ${res.body}');
    }
    final serverFp =
        (jsonDecode(res.body) as Map<dynamic, dynamic>)['serverFingerprint']
            as String;
    if (serverFp != pinnedFingerprint) {
      throw MlfClientException(
        'server fingerprint mismatch: pinned $pinnedFingerprint, got $serverFp',
      );
    }
    _clientFingerprint = clientFingerprint.toLowerCase();
    return serverFp;
  }

  Future<List<FsEntry>> list(Uri base, String path) async {
    final res = await _inner.get(
      resolve(base, 'fs/list').replace(queryParameters: {'path': path}),
      headers: _authHeaders,
    );
    if (res.statusCode != 200) {
      throw MlfClientException('list failed: ${res.statusCode} ${res.body}');
    }
    final body = jsonDecode(res.body) as Map<dynamic, dynamic>;
    return (body['entries'] as List)
        .map((m) => FsEntry.fromMap(m as Map<dynamic, dynamic>))
        .toList();
  }

  /// Streams a file (Range semantics via [offset]/[length] — resume path).
  Future<http.StreamedResponse> read(
    Uri base,
    String path, {
    int offset = 0,
    int? length,
  }) async {
    final res = await _inner.send(
      http.Request(
        'GET',
        resolve(base, 'fs/read').replace(
          queryParameters: {
            'path': path,
            if (offset > 0) 'offset': '$offset',
            if (length != null) 'length': '$length',
          },
        ),
      )..headers.addAll(_authHeaders),
    );
    if (res.statusCode != 200) {
      await res.stream.drain<void>().catchError((Object _) {});
      throw MlfClientException('read failed: ${res.statusCode}');
    }
    return res;
  }

  /// Opens the §4.2 packed stream. [skip] holds SHA-256 hex of files the
  /// client already has; the server omits those frames (file-level resume).
  /// Frame data must be consumed via [PackStreamReader.next].
  Future<PackStreamReader> pack(
    Uri base,
    List<String> items, {
    Set<String> skip = const {},
  }) async {
    final res = await _inner.send(
      http.Request('POST', resolve(base, 'pack'))
        ..headers.addAll(_authHeaders)
        ..headers['content-type'] = 'application/json'
        ..body = jsonEncode({'items': items, 'skip': skip.toList()}),
    );
    if (res.statusCode != 200) {
      await res.stream.drain<void>().catchError((Object _) {});
      throw MlfClientException('pack failed: ${res.statusCode}');
    }
    return PackStreamReader(res.stream);
  }

  /// 缩略图字节(§4.1 /thumb;token 来自 media/list 条目)。
  Future<Uint8List> thumb(Uri base, String token, {int size = 320}) async {
    final res = await _inner.get(
      resolve(
        base,
        'thumb',
      ).replace(queryParameters: {'token': token, 'size': '$size'}),
      headers: _authHeaders,
    );
    if (res.statusCode != 200) {
      throw MlfClientException('thumb failed: ${res.statusCode}');
    }
    return res.bodyBytes;
  }

  /// GET any §4.1 endpoint and parse the JSON body (tests/tools helper).
  Future<dynamic> getJson(Uri base, String endpointAndQuery) async {
    final res = await _inner.get(
      resolve(base, endpointAndQuery),
      headers: _authHeaders,
    );
    if (res.statusCode != 200) {
      throw MlfClientException(
        'GET $endpointAndQuery failed: ${res.statusCode}',
      );
    }
    return jsonDecode(res.body);
  }

  /// Raw chunked PUT (§4.1 fs/write). [offset] > 0 resumes the remote file
  /// at that byte position. Returns (remote size, remote sha256 hex) — the
  /// server hashes on the fly (upload integrity receipt).
  Future<(int, String)> write(
    Uri base,
    String path,
    Stream<List<int>> body,
    int offset,
  ) async {
    final req = http.StreamedRequest(
      'PUT',
      resolve(
        base,
        'fs/write',
      ).replace(queryParameters: {'path': path, 'offset': '$offset'}),
    )..headers.addAll(_authHeaders);
    unawaited(req.sink.addStream(body).then((_) => req.sink.close()));
    final res = await _inner.send(req);
    if (res.statusCode != 200) {
      await res.stream.drain<void>().catchError((Object _) {});
      throw MlfClientException('write failed: ${res.statusCode}');
    }
    final parsed =
        jsonDecode(await res.stream.bytesToString()) as Map<dynamic, dynamic>;
    return ((parsed['size'] as num).toInt(), parsed['sha256'] as String? ?? '');
  }

  /// Generic fs/op invocation (§4.1): copy|move|delete|rename|mkdir.
  Future<void> op(Uri base, String op, Map<String, dynamic> args) async {
    final res = await _inner.send(
      http.Request('POST', resolve(base, 'fs/op'))
        ..headers.addAll(_authHeaders)
        ..headers['content-type'] = 'application/json'
        ..body = jsonEncode({'op': op, 'args': args}),
    );
    if (res.statusCode != 200) {
      await res.stream.drain<void>().catchError((Object _) {});
      throw MlfClientException('op $op failed: ${res.statusCode}');
    }
  }

  /// Atomic resumable upload of [file] into remote directory [targetDir]
  /// (virtual path, '/' = root). Streams into `<name>.mlfpart` remotely
  /// (offset = existing part size → resume), then renames to the final name
  /// only after the full length is confirmed — a partial upload never
  /// shadows a complete file. [onProgress] gets (sent, total) updates.
  Future<void> upload(
    Uri base,
    File file,
    String targetDir, {
    void Function(int sent, int total)? onProgress,
  }) async {
    final name = sanitizeFilename(file.uri.pathSegments.last);
    final dir = targetDir.endsWith('/') ? targetDir : '$targetDir/';
    final partPath = '$dir$name.mlfpart';

    // Ensure the target directory exists (mkdir is idempotent server-side).
    try {
      await op(base, 'mkdir', {'path': dir, 'recursive': true});
    } on MlfClientException {
      // 409 already-exists is fine; anything else surfaces in the upload.
    }

    // Resume point = whatever the remote already holds.
    var offset = 0;
    final total = await file.length();
    try {
      final entries = await list(base, dir);
      for (final e in entries) {
        if (e.name == '$name.mlfpart') {
          offset = e.size;
          break;
        }
      }
    } on MlfClientException {
      offset = 0; // dir not listable (e.g. missing) — start fresh
    }
    if (offset > total) {
      offset = 0; // remote part longer than the local file — it changed
    }

    onProgress?.call(offset, total);
    var sent = offset;
    final (size, remoteSha) = await write(
      base,
      partPath,
      countBytes(
        file.openRead(offset),
        (d) => onProgress?.call(sent += d, total),
      ),
      offset,
    );
    if (size != total) {
      throw MlfClientException(
        'upload incomplete: server reports $size of $total bytes',
      );
    }
    // 完整性回执:全新上传(offset==0)时服务端哈希即全文件哈希,逐字节比对;
    // 续传时回执仅覆盖本次追加段,以长度校验为准(语义记录于协议注释)。
    final localSha = offset == 0 ? await sha256FileHex(file) : remoteSha;
    if (remoteSha.isNotEmpty && remoteSha != localSha) {
      await op(base, 'delete', {'path': partPath});
      throw MlfClientException(
        'upload integrity mismatch (remote $remoteSha, local $localSha)',
      );
    }
    await op(base, 'rename', {'path': partPath, 'newName': name});
    onProgress?.call(total, total);
  }

  void close() => _inner.close();
}

/// SHA-256 hex of a local file (streamed — used to build the skip set).
Future<String> sha256FileHex(File file) async =>
    toHex((await sha256.bind(file.openRead()).first).bytes as Uint8List);

/// Byte-counting tee: forwards chunks unchanged, reports deltas to [onBytes]
/// (progress UI feeds total bytes received).
Stream<List<int>> countBytes(
  Stream<List<int>> source,
  void Function(int delta) onBytes,
) async* {
  await for (final chunk in source) {
    onBytes(chunk.length);
    yield chunk;
  }
}

/// First site-local IPv4 address of this host (what goes into the QR).
Future<String?> lanIPv4() async {
  final interfaces = await NetworkInterface.list(
    type: InternetAddressType.IPv4,
    includeLoopback: false,
    includeLinkLocal: false,
  );
  for (final interface in interfaces) {
    for (final addr in interface.addresses) {
      final octets = addr.address.split('.').map(int.parse).toList();
      final siteLocal =
          octets[0] == 10 ||
          octets[0] == 192 && octets[1] == 168 ||
          octets[0] == 172 && octets[1] >= 16 && octets[1] <= 31;
      if (siteLocal) {
        return addr.address;
      }
    }
  }
  return interfaces.isNotEmpty
      ? interfaces.first.addresses.first.address
      : null;
}
