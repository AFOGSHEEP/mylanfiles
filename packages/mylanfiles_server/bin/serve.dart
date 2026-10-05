import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:mylanfiles_core/mylanfiles_core.dart';
import 'package:mylanfiles_server/mylanfiles_server.dart';

/// MyLanFiles 无头服务器(初版 demo 三件套之一)。
///
/// 单二进制部署到任意机器(NAS/Linux/Windows/macOS 均可从各自平台编译),
/// 把一个目录变成可被 MyLanFiles 客户端(手机/桌面 App)发现并浏览的共享端:
///
/// ```sh
/// mlf-serve --root /srv/share --alias NAS
/// # → 服务发现自动可见;首次连接扫码/点选「附近设备」即配对
/// ```
///
/// 安全模型与 App 完全一致:自签 TLS + 指纹 pin 配对 + PathGuard + 双限速。
/// 身份与配对表存放在共享根**之外**的 `<root>-mlf-identity/`(私钥不可经共享根泄露)。
Future<void> main(List<String> args) async {
  String root = Directory.current.path;
  String? alias;
  int? wantPort;
  var allowPairing = true;
  for (var i = 0; i < args.length; i++) {
    switch (args[i]) {
      case '--root':
        root = args[++i];
      case '--alias':
        alias = args[++i];
      case '--port':
        wantPort = int.tryParse(args[++i]) ?? 0;
      case '--no-pair':
        allowPairing = false;
      case '--help' || '-h':
        stdout.writeln(
          'usage: mlf-serve [--root DIR] [--alias NAME] [--port N] [--no-pair]',
        );
        exit(0);
    }
  }

  final rootDir = Directory(root);
  if (!rootDir.existsSync()) {
    stderr.writeln('root 不存在: $root');
    exit(2);
  }
  // 身份目录:共享根的同级伴生目录(在根外)。
  final rootName = rootDir.path
      .replaceAll(Platform.isWindows ? '\\' : 'X', '/')
      .split('/')
      .where((s) => s.isNotEmpty)
      .last;
  final identityDir = Directory(
    '${rootDir.parent.path}/$rootName-mlf-identity',
  );

  final identity = await loadOrCreateIdentity(identityDir);
  final prefsFile = File('${identityDir.path}/server.json');
  Map<dynamic, dynamic> prefs = {};
  try {
    if (await prefsFile.exists()) {
      prefs =
          jsonDecode(await prefsFile.readAsString()) as Map<dynamic, dynamic>;
    }
  } on Object {
    /* 损坏重来 */
  }

  final savedPort = wantPort ?? (prefs['port'] as num?)?.toInt() ?? 0;
  final savedPaired = ((prefs['paired'] as List?) ?? const [])
      .whereType<String>()
      .toSet();

  final serverRef = <MlfServer>[];
  final server = MlfServer(
    vfs: LocalVfs(root: rootDir.path),
    serverFingerprint: identity.fingerprint,
    pairedFingerprints: savedPaired,
    allowPairing: allowPairing,
    onPaired: (fp) {
      final s = serverRef.isEmpty ? null : serverRef.first;
      if (s != null) {
        unawaited(
          prefsFile.writeAsString(
            jsonEncode({
              'port': s.port,
              'paired': s.pairedFingerprints.toList(),
            }),
            flush: true,
          ),
        );
      }
    },
  );
  serverRef.add(server);

  var bound = false;
  if (savedPort > 0) {
    try {
      await server.bind(
        InternetAddress.anyIPv4,
        savedPort,
        securityContext: identity.context,
      );
      bound = true;
    } on Object {
      stderr.writeln('端口 $savedPort 被占用,改用随机端口');
    }
  }
  if (!bound) {
    await server.bind(
      InternetAddress.anyIPv4,
      0,
      securityContext: identity.context,
    );
  }
  await prefsFile.writeAsString(
    jsonEncode({
      'port': server.port,
      'paired': server.pairedFingerprints.toList(),
    }),
    flush: true,
  );

  final lanIp = await lanIPv4();
  final deviceAlias = (alias != null && alias.isNotEmpty)
      ? alias
      : (Platform.localHostname.isEmpty
            ? 'mlf-server'
            : Platform.localHostname);
  final pairing = MlfPairingInfo(
    ip: lanIp ?? '127.0.0.1',
    port: server.port,
    fingerprint: identity.fingerprint,
    alias: deviceAlias,
  );

  final announcer = DiscoveryAnnouncer(
    alias: deviceAlias,
    port: server.port,
    fingerprint: identity.fingerprint,
  );
  await announcer.start();

  stdout.writeln('[mlf-serve] root   = ${rootDir.path}');
  stdout.writeln('[mlf-serve] https  = https://$lanIp:${server.port}');
  stdout.writeln('[mlf-serve] alias  = $deviceAlias');
  stdout.writeln('[mlf-serve] PAIRING_JSON ${jsonEncode(pairing.toJson())}');
  stdout.writeln('[mlf-serve] Ctrl+C 停止');

  ProcessSignal.sigint.watch().listen((_) async {
    stdout.writeln('\n[mlf-serve] shutting down...');
    await announcer.stop();
    await server.stop();
    exit(0);
  });

  await Completer<void>().future; // 常驻
}
