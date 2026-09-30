import 'dart:math';

/// Sliding-window rate limiter for unpaired/rejected requesters (交接文档 §7-3:
/// 未配对 IP 限速 + 黑名单).
class RateLimiter {
  RateLimiter({this.maxFailures = 5, this.window = const Duration(minutes: 1)});

  final int maxFailures;
  final Duration window;

  final Map<String, List<DateTime>> _failures = {};
  final Map<String, DateTime> _blockedUntil = {};

  /// Whether [key] (client ip) is currently blocked.
  bool isBlocked(String key) {
    final until = _blockedUntil[key];
    if (until == null) return false;
    if (DateTime.now().isAfter(until)) {
      _blockedUntil.remove(key);
      _failures.remove(key);
      return false;
    }
    return true;
  }

  /// Records a rejected attempt; blocks the key once the window overflows.
  void recordFailure(String key) {
    final now = DateTime.now();
    final list = _failures.putIfAbsent(key, () => []);
    list.add(now);
    while (list.isNotEmpty && now.difference(list.first) > window) {
      list.removeAt(0);
    }
    if (list.length >= maxFailures) {
      _blockedUntil[key] = now.add(window);
      _failures.remove(key);
    }
  }

  /// Clears all state (used after a successful pairing in tests).
  void reset() {
    _failures.clear();
    _blockedUntil.clear();
  }
}

/// Fingerprint format check: SHA-256 hex (64 chars).
final _fingerprintPattern = RegExp(r'^[0-9a-f]{64}$');

bool isValidFingerprint(String? value) =>
    value != null && _fingerprintPattern.hasMatch(value.toLowerCase());

/// Deterministic pseudo fingerprint for tests/dev (NOT for production QR
/// pairing, where it comes from the TLS certificate's public key hash).
String devFingerprint(String seed) {
  var h = 0x811c9dc5;
  for (final b in seed.codeUnits) {
    h = (h ^ b) & 0xffffffff;
    h = (h * 0x01000193) & 0xffffffff;
  }
  final rng = Random(h);
  return List.generate(64, (_) => '0123456789abcdef'[rng.nextInt(16)]).join();
}
