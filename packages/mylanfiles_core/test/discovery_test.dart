import 'dart:convert';
import 'dart:io';

import 'package:mylanfiles_core/mylanfiles_core.dart';
import 'package:test/test.dart';

void main() {
  test('announcer → listener round-trip on loopback broadcast', () async {
    final received = <DiscoveredServer>[];
    final listener = DiscoveryListener(
      onChanged: (servers) => received.addAll(servers),
    );
    await listener.start();
    addTearDown(listener.stop);

    final announcer = DiscoveryAnnouncer(
      alias: '测试机',
      port: 12345,
      fingerprint: 'a' * 64,
    );
    await announcer.start();
    addTearDown(announcer.stop);

    // 广播至少一次宣告周期
    await Future<void>.delayed(const Duration(milliseconds: 4200));

    expect(received, isNotEmpty, reason: 'listener should see the announcer');
    final seen = listener.servers;
    expect(seen, isNotEmpty);
    // 同一台宣告者去重:多轮宣告仍只有一个 peer
    expect(seen.where((s) => s.fingerprint == 'a' * 64).length, 1);
    final peer = seen.firstWhere((s) => s.fingerprint == 'a' * 64);
    expect(peer.port, 12345);
    expect(peer.alias, '测试机');
    expect(peer.pairingJson, contains('"proto":"mlf"'));
  }, timeout: const Timeout(Duration(minutes: 1)));

  test('malformed announcements are ignored', () async {
    final listener = DiscoveryListener();
    await listener.start();
    addTearDown(listener.stop);
    final sock = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
    addTearDown(sock.close);
    void send(String s) => sock.send(
      utf8.encode(s),
      InternetAddress('255.255.255.255'),
      mlfDiscoveryPort,
    );
    send('not json');
    send('{"proto":"mlf-disc"}'); // 缺 fp/port
    send('{"proto":"mlf-disc","port":1,"fp":"short"}');
    send('{"proto":"other","port":1,"fp":"' + 'b' * 64 + '"}');
    await Future<void>.delayed(const Duration(milliseconds: 800));
    expect(listener.servers.where((s) => s.fingerprint.length != 64), isEmpty);
    expect(
      listener.servers.where((s) => s.fingerprint == 'b' * 64),
      isEmpty,
      reason: 'non-mlf proto must be dropped',
    );
  }, timeout: const Timeout(Duration(minutes: 1)));

  test('peers age out after timeout', () async {
    final listener = DiscoveryListener();
    await listener.start();
    addTearDown(listener.stop);
    final announcer = DiscoveryAnnouncer(
      alias: 'x',
      port: 9,
      fingerprint: 'c' * 64,
    );
    await announcer.start();
    await Future<void>.delayed(const Duration(milliseconds: 3400));
    expect(
      listener.servers.where((s) => s.fingerprint == 'c' * 64),
      isNotEmpty,
    );
    await announcer.stop();
    // 12s 超时 + 3s 扫描周期
    await Future<void>.delayed(const Duration(seconds: 16));
    expect(listener.servers.where((s) => s.fingerprint == 'c' * 64), isEmpty);
  }, timeout: const Timeout(Duration(minutes: 2)));
}
