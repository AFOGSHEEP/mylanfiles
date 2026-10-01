import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'dart:io'
    show
        FileSystemException,
        HttpConnectionInfo,
        HttpServer,
        InternetAddress,
        SecurityContext;

import 'package:crypto/crypto.dart';
import 'package:mylanfiles_core/mylanfiles_core.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:shelf_router/shelf_router.dart';

import 'auth.dart';

const _fingerprintHeader = 'x-mlf-fingerprint';

/// MyLanFiles embedded server (交接文档 §4.1).
///
/// Every business request must carry [_fingerprintHeader] with an already
/// paired fingerprint; unpaired requests are rejected before touching the
/// VFS (§7-3) and rate-limited per IP.
class MlfServer {
  MlfServer({
    required Vfs vfs,
    required String serverFingerprint,
    Set<String> pairedFingerprints = const {},
    bool allowPairing = true,
    RateLimiter? rateLimiter,
  }) : _vfs = vfs,
       _serverFingerprint = serverFingerprint,
       _paired = {...pairedFingerprints},
       _allowPairing = allowPairing,
       _rateLimiter = rateLimiter ?? RateLimiter();

  final Vfs _vfs;
  final String _serverFingerprint;
  final Set<String> _paired;
  final bool _allowPairing;
  final RateLimiter _rateLimiter;
  HttpServer? _http;

  set pairedFingerprints(Set<String> value) {
    _paired
      ..clear()
      ..addAll(value);
  }

  Set<String> get pairedFingerprints => Set.unmodifiable(_paired);

  /// The shelf handler (also handy for in-process tests without a socket).
  Handler get handler {
    final router = Router()
      ..post('/api/v1/pair', _pair)
      ..get('/api/v1/fs/list', _list)
      ..get('/api/v1/fs/read', _read)
      ..put('/api/v1/fs/write', _write)
      ..post('/api/v1/fs/op', _op)
      ..post('/api/v1/pack', _pack);
    return const Pipeline().addMiddleware(_auth()).addHandler(router.call);
  }

  /// Binds on [address]:[port] ([SecurityContext] → https, else http).
  Future<void> bind(
    InternetAddress address,
    int port, {
    SecurityContext? securityContext,
  }) async {
    if (securityContext != null) {
      _http = await shelf_io.serve(
        handler,
        address,
        port,
        securityContext: securityContext,
      );
    } else {
      _http = await shelf_io.serve(handler, address, port);
    }
  }

  Future<void> stop() async {
    await _http?.close(force: true);
    _http = null;
  }

  int get port => _http?.port ?? 0;

  /// Clears the failure/block state (e.g. after a successful QR pairing).
  void resetRateLimits() => _rateLimiter.reset();

  // ---- middleware ----

  Middleware _auth() =>
      (Handler inner) => (Request req) async {
        final info =
            req.context['shelf.io.connection_info'] as HttpConnectionInfo?;
        final ip = info?.remoteAddress.address ?? 'unknown';
        if (_rateLimiter.isBlocked(ip)) {
          return Response(
            429,
            body: jsonEncode({'error': 'too many failures'}),
          );
        }
        // Pairing is how a client BECOMES paired — exempt it from the gate
        // (the endpoint itself checks _allowPairing and rate limits still apply).
        if ('/${req.url.path}' == '/api/v1/pair' && _allowPairing) {
          return inner(req);
        }
        final fingerprint = req.headers[_fingerprintHeader]?.toLowerCase();
        if (!isValidFingerprint(fingerprint) ||
            !_paired.contains(fingerprint)) {
          _rateLimiter.recordFailure(ip);
          return Response(403, body: jsonEncode({'error': 'not paired'}));
        }
        return inner(req);
      };

  // ---- endpoints ----

  Future<Response> _pair(Request req) async {
    if (!_allowPairing) {
      return Response(404, body: jsonEncode({'error': 'pairing disabled'}));
    }
    final body = jsonDecode(await req.readAsString()) as Map<dynamic, dynamic>;
    final fingerprint = (body['fingerprint'] as String?)?.toLowerCase();
    if (!isValidFingerprint(fingerprint)) {
      return Response(400, body: jsonEncode({'error': 'invalid fingerprint'}));
    }
    _paired.add(fingerprint!);
    return Response.ok(
      jsonEncode({'status': 'paired', 'serverFingerprint': _serverFingerprint}),
    );
  }

  Future<Response> _list(Request req) async {
    try {
      final path = req.url.queryParameters['path'] ?? '/';
      final entries = await _vfs.list(path);
      return Response.ok(
        jsonEncode({
          'path': path,
          'entries': entries.map((e) => e.toMap()).toList(),
        }),
        headers: _jsonHeaders,
      );
    } on PathAccessException {
      return _forbidden();
    } on VfsNotFoundException {
      return _notFound();
    }
  }

  Future<Response> _read(Request req) async {
    final params = req.url.queryParameters;
    final offset = int.tryParse(params['offset'] ?? '0') ?? 0;
    final length = params['length'] == null
        ? null
        : int.tryParse(params['length']!);
    if (offset < 0 || (length != null && length < 0)) {
      return Response(400, body: jsonEncode({'error': 'bad range'}));
    }
    // Eager validation first: the VFS stream is lazy, so without this the
    // status line would already be gone when containment/404/409 surfaces.
    try {
      final entry = await _vfs.stat(params['path'] ?? '/');
      if (entry.isDir) {
        return _conflict('is a directory');
      }
      if (entry.size < offset) {
        return Response(400, body: jsonEncode({'error': 'offset past EOF'}));
      }
    } on PathAccessException {
      return _forbidden();
    } on VfsNotFoundException {
      return _notFound();
    }
    final stream = _vfs.read(
      params['path'] ?? '/',
      offset: offset,
      length: length,
    );
    return Response.ok(
      stream,
      headers: {'content-type': 'application/octet-stream'},
    );
  }

  Future<Response> _write(Request req) async {
    final params = req.url.queryParameters;
    final offset = int.tryParse(params['offset'] ?? '0') ?? 0;
    if (offset < 0) {
      return Response(400, body: jsonEncode({'error': 'bad offset'}));
    }
    try {
      final size = await _vfs.write(
        params['path'] ?? '/',
        req.read(),
        offset: offset,
      );
      return Response.ok(jsonEncode({'size': size}), headers: _jsonHeaders);
    } on PathAccessException {
      return _forbidden();
    } on VfsIsDirException {
      return _conflict('is a directory');
    } on FileSystemException catch (e) {
      return Response(500, body: jsonEncode({'error': e.message}));
    }
  }

  Future<Response> _op(Request req) async {
    Map<dynamic, dynamic> body;
    try {
      body = jsonDecode(await req.readAsString()) as Map<dynamic, dynamic>;
    } on FormatException {
      return Response(400, body: jsonEncode({'error': 'bad json'}));
    }
    final op = body['op'] as String?;
    final args = (body['args'] as Map?)?.cast<String, dynamic>() ?? {};
    try {
      switch (op) {
        case 'mkdir':
          await _vfs.mkdir(
            args['path'] as String,
            recursive: args['recursive'] as bool? ?? false,
          );
          break;
        case 'delete':
          await _vfs.delete(
            args['path'] as String,
            recursive: args['recursive'] as bool? ?? false,
          );
          break;
        case 'rename':
          await _vfs.rename(args['path'] as String, args['newName'] as String);
          break;
        case 'copy':
          await _vfs.copy(args['path'] as String, args['targetDir'] as String);
          break;
        case 'move':
          await _vfs.move(args['path'] as String, args['targetDir'] as String);
          break;
        default:
          return Response(400, body: jsonEncode({'error': 'unknown op: $op'}));
      }
      return Response.ok(jsonEncode({'status': 'ok'}), headers: _jsonHeaders);
    } on PathAccessException {
      return _forbidden();
    } on VfsNotFoundException {
      return _notFound();
    } on VfsConflictException catch (e) {
      return _conflict(e.path);
    } on VfsIsDirException {
      return _conflict('is a directory');
    }
  }

  /// POST /api/v1/pack  body={items:[path...], skip:[sha256hex...]}
  /// → 连续帧流（§4.2），已存在（sha 命中 skip）的文件不出帧。
  Future<Response> _pack(Request req) async {
    Map<dynamic, dynamic> body;
    try {
      body = jsonDecode(await req.readAsString()) as Map<dynamic, dynamic>;
    } on FormatException {
      return Response(400, body: jsonEncode({'error': 'bad json'}));
    }
    final items = (body['items'] as List?)?.cast<String>() ?? const [];
    final skip = (body['skip'] as List?)?.cast<String>().toSet() ?? <String>{};

    // Eager validation: all items must resolve to files inside the root,
    // otherwise the error would surface after the 200 went out.
    final entries = <FsEntry>[];
    for (final item in items) {
      try {
        final entry = await _vfs.stat(item);
        if (entry.isDir) {
          return _conflict('pack item is a directory: $item');
        }
        entries.add(entry);
      } on PathAccessException {
        return _forbidden();
      } on VfsNotFoundException {
        return _notFound();
      }
    }

    Stream<List<int>> frames() async* {
      for (final entry in entries) {
        // Pass 1: hash while streaming (never buffer the whole file).
        final digest = sha256.bind(_vfs.read(entry.path));
        final sha = (await digest.first).bytes as Uint8List;
        if (skip.contains(toHex(sha))) {
          continue; // §4.2: 文件粒度断点——已有则整帧不发
        }
        yield encodeFrameHeader(entry.name, entry.size, sha);
        yield* _vfs.read(entry.path);
      }
      yield encodeStreamEnd();
    }

    return Response.ok(
      frames(),
      headers: {'content-type': 'application/octet-stream'},
    );
  }

  // ---- helpers ----

  static const _jsonHeaders = {
    'content-type': 'application/json; charset=utf-8',
  };

  Response _forbidden() =>
      Response(403, body: jsonEncode({'error': 'forbidden'}));
  Response _notFound() =>
      Response(404, body: jsonEncode({'error': 'not found'}));
  Response _conflict(String reason) =>
      Response(409, body: jsonEncode({'error': reason}));
}
