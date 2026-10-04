import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// 设备自动发现（大众化第一入口）：UDP 广播宣告 + 监听。
///
/// 设计要点：
/// - **广播而非组播**：Android 仅在接收*组播*时需要 MulticastLock；子网/受限
///   广播的收发都不需要，零平台通道、零权限新增。
/// - 宣告载荷 `{v,proto:'mlf-disc',alias,port,fp}` 与二维码同构——发现到的
///   设备点一下即走与扫码完全相同的 pin 配对路径（TOFU：fp 连续性由
///   remembered-servers 保证，指纹变化会在 TLS 握手被 pin 拒绝）。
/// - 服务端只在「本机服务运行」期间宣告；客户端在浏览页打开期间监听。
const mlfDiscoveryPort = 57778;
const _announceInterval = Duration(seconds: 3);
const _peerTimeout = Duration(seconds: 12);

class DiscoveredServer {
  DiscoveredServer({
    required this.alias,
    required this.ip,
    required this.port,
    required this.fingerprint,
    required this.lastSeen,
  });

  final String alias;
  final String ip;
  final int port;
  final String fingerprint;
  DateTime lastSeen;

  String get pairingJson => jsonEncode({
    'v': 1,
    'proto': 'mlf',
    'ip': ip,
    'port': port,
    'fp': fingerprint,
    'al': alias,
  });

  @override
  bool operator ==(Object other) =>
      other is DiscoveredServer &&
      other.ip == ip &&
      other.port == port &&
      other.fingerprint == fingerprint;

  @override
  int get hashCode => Object.hash(ip, port, fingerprint);
}

/// 服务端：每 3 秒向本网段广播自己（alias/port/fp）。
class DiscoveryAnnouncer {
  DiscoveryAnnouncer({
    required this.alias,
    required this.port,
    required this.fingerprint,
  });

  final String alias;
  final int port;
  final String fingerprint;

  RawDatagramSocket? _socket;
  Timer? _timer;
  bool _running = false;

  Future<void> start() async {
    if (_running) {
      return;
    }
    _running = true;
    _socket = await RawDatagramSocket.bind(
      InternetAddress.anyIPv4,
      0,
      reuseAddress: true,
    );
    _socket!.broadcastEnabled = true; // Windows/POSIX 发受限广播的必要开关
    _announce();
    _timer = Timer.periodic(_announceInterval, (_) => _announce());
  }

  void _announce() {
    final s = _socket;
    if (s == null) {
      return;
    }
    final payload = utf8.encode(
      jsonEncode({
        'v': 1,
        'proto': 'mlf-disc',
        'al': alias,
        'port': port,
        'fp': fingerprint,
      }),
    );
    // 双保险：受限广播覆盖局域网；逐接口单播覆盖「同机测试」与个别
    // 拒绝受限广播的网络(广播默认不回环,本机靠单播自达)。
    try {
      s.send(payload, InternetAddress('255.255.255.255'), mlfDiscoveryPort);
    } on Object {
      /* 受限广播被拒时仍有下面的单播 */
    }
    // 回环单播:127.0.0.1 免防火墙,支撑同机发现(本机演示)与单元测试。
    try {
      s.send(payload, InternetAddress.loopbackIPv4, mlfDiscoveryPort);
    } on Object {
      /* 忽略 */
    }
    // 各接口地址单播:覆盖拒绝受限广播的个别网络。
    unawaited(
      NetworkInterface.list(
            type: InternetAddressType.IPv4,
            includeLoopback: false,
            includeLinkLocal: false,
          )
          .then((interfaces) {
            for (final i in interfaces) {
              for (final addr in i.addresses) {
                try {
                  s.send(payload, addr, mlfDiscoveryPort);
                } on Object {
                  /* 单地址失败忽略 */
                }
              }
            }
          })
          .catchError((Object _) {}),
    );
  }

  Future<void> stop() async {
    _timer?.cancel();
    _timer = null;
    _socket?.close();
    _socket = null;
    _running = false;
  }
}

/// 客户端：监听广播,聚合附近设备(12s 未见即移除),变化时回调。
class DiscoveryListener {
  DiscoveryListener({this.onChanged});

  final void Function(List<DiscoveredServer> servers)? onChanged;

  RawDatagramSocket? _socket;
  final Map<String, DiscoveredServer> _peers = {};
  Timer? _sweep;

  Future<void> start() async {
    if (_socket != null) {
      return;
    }
    _socket = await RawDatagramSocket.bind(
      InternetAddress.anyIPv4,
      mlfDiscoveryPort,
      reuseAddress: true,
      // Windows 不支持 reusePort;Linux/Android/macOS 上允许多监听者共存。
      reusePort: !Platform.isWindows,
      // 广播接收(非组播)在 Android 无需 MulticastLock。
    );
    _socket!.listen((event) {
      if (event != RawSocketEvent.read) {
        return;
      }
      final dg = _socket!.receive();
      if (dg == null) {
        return;
      }
      _handle(dg.data, dg.address.address);
    });
    _sweep = Timer.periodic(const Duration(seconds: 3), (_) {
      final now = DateTime.now();
      final before = _peers.length;
      _peers.removeWhere((_, p) => now.difference(p.lastSeen) > _peerTimeout);
      if (_peers.length != before) {
        onChanged?.call(List.of(_peers.values));
      }
    });
  }

  void _handle(List<int> data, String fromIp) {
    try {
      final m = jsonDecode(utf8.decode(data)) as Map<dynamic, dynamic>;
      if (m['proto'] != 'mlf-disc') {
        return;
      }
      final fp = (m['fp'] as String?)?.toLowerCase();
      final port = (m['port'] as num?)?.toInt();
      if (fp == null || fp.length != 64 || port == null) {
        return; // 畸形宣告直接丢弃
      }
      // 按指纹去重:同一设备会经回环与局域网地址重复宣告(自达双路径),
      // 保留非回环地址(对端真实可达地址)。
      final existed = _peers[fp];
      if (existed != null) {
        final fromLoopback = fromIp == InternetAddress.loopbackIPv4.address;
        if (existed.ip == InternetAddress.loopbackIPv4.address &&
            !fromLoopback) {
          _peers[fp] = DiscoveredServer(
            alias: (m['al'] as String?)?.isNotEmpty == true
                ? m['al'] as String
                : fromIp,
            ip: fromIp,
            port: port,
            fingerprint: fp,
            lastSeen: DateTime.now(),
          );
          onChanged?.call(List.of(_peers.values));
        } else {
          existed.lastSeen = DateTime.now();
        }
        return;
      }
      _peers[fp] = DiscoveredServer(
        alias: (m['al'] as String?)?.isNotEmpty == true
            ? m['al'] as String
            : fromIp,
        ip: fromIp,
        port: port,
        fingerprint: fp,
        lastSeen: DateTime.now(),
      );
      onChanged?.call(List.of(_peers.values));
    } on Object {
      /* 非法包忽略 */
    }
  }

  List<DiscoveredServer> get servers => List.unmodifiable(_peers.values);

  Future<void> stop() async {
    _sweep?.cancel();
    _sweep = null;
    _socket?.close();
    _socket = null;
    _peers.clear();
  }
}
