import 'dart:async';
import 'dart:collection';

import 'package:flutter/foundation.dart';

/// Transfer mode chosen for a multi-file download (交接文档 §4.2 自适应规则:
/// 中位文件 < 2 MiB 走打包流,否则逐文件——后者可享受单文件 Range 续传).
enum TransferMode { pack, sequential }

TransferMode pickTransferMode(Iterable<int> fileSizes) {
  final sizes = fileSizes.toList()..sort();
  if (sizes.isEmpty) {
    return TransferMode.sequential;
  }
  final median = sizes.length.isOdd ? sizes[sizes.length ~/ 2] : sizes[sizes.length ~/ 2 - 1];
  return median < 2 * 1024 * 1024 ? TransferMode.pack : TransferMode.sequential;
}

enum TransferState { queued, running, done, failed, canceled }

enum TransferKind { singleFile, pack, upload }

/// Thrown by runners when the user cancels; the queue marks the task
/// canceled instead of failed (partial data is kept where meaningful).
class TaskCanceledException implements Exception {
  const TaskCanceledException();
}

/// One row in the queue. The actual IO lives in [runner]; progress is
/// reported back through [addBytes] / [setDetail].
class TransferTask extends ChangeNotifier {
  TransferTask({
    required this.label,
    required this.kind,
    required this.totalBytes,
    required this.runner,
  });

  final String label;
  final TransferKind kind;
  final int totalBytes;

  /// Performs the transfer; call [addBytes] as data arrives. Thrown errors
  /// mark the task failed; [TaskCanceledException] marks it canceled (retry
  /// may resume — e.g. the `.part` file is kept).
  final Future<void> Function(TransferTask task) runner;

  int receivedBytes = 0;
  TransferState state = TransferState.queued;
  String? error;

  /// Free-form status ("正在 b.txt 3/10"、"跳过 2 个已存在").
  String detail = '';

  bool _cancelRequested = false;

  /// 自动重试已用次数（退避表用尽才标记 failed）。
  int autoRetries = 0;

  /// 自动重试的最早启动时间（退避期间保持 queued 但不被取出）。
  DateTime? notBefore;

  Duration _notifyInterval = const Duration(milliseconds: 80);
  DateTime _lastNotify = DateTime.fromMillisecondsSinceEpoch(0);

  @visibleForTesting
  set notifyInterval(Duration value) => _notifyInterval = value;

  bool get cancelRequested => _cancelRequested;

  /// Requests cancellation; runners observe it at their next checkpoint.
  void cancel() {
    if (state == TransferState.done) {
      return;
    }
    _cancelRequested = true;
  }

  double get progress => totalBytes <= 0 ? (state == TransferState.done ? 1.0 : 0.0) : (receivedBytes / totalBytes).clamp(0.0, 1.0);

  /// Records received bytes; coalesces notifications (progress UI only).
  void addBytes(int delta) {
    if (delta <= 0) {
      return;
    }
    receivedBytes += delta;
    final now = DateTime.now();
    if (now.difference(_lastNotify) >= _notifyInterval) {
      _lastNotify = now;
      notifyListeners();
    }
  }

  void setDetail(String value) {
    if (detail == value) {
      return;
    }
    detail = value;
    notifyListeners();
  }

  @override
  String toString() => 'TransferTask($label, $state, $receivedBytes/$totalBytes)';
}

/// Sequential transfer queue: one task on the wire at a time (saturating a
/// single WLAN link needs no parallelism; ordering keeps the UI honest).
class TransferQueue extends ChangeNotifier {
  TransferQueue({List<Duration>? backoffSchedule}) : _backoffSchedule = backoffSchedule ?? const [Duration(seconds: 2), Duration(seconds: 8)];

  final Queue<TransferTask> _tasks = Queue();
  bool _draining = false;
  Timer? _backoffTimer;

  /// 自动重试退避表（默认 2s、8s；测试可注入更短值）。
  final List<Duration> _backoffSchedule;

  List<TransferTask> get tasks => List.unmodifiable(_tasks);

  bool get isBusy => _tasks.any((t) => t.state == TransferState.running);

  int get activeCount => _tasks
      .where(
        (t) => t.state == TransferState.queued || t.state == TransferState.running,
      )
      .length;

  void enqueue(TransferTask task) {
    _tasks.add(task);
    notifyListeners();
    unawaited(_drain());
  }

  Future<void> _drain() async {
    if (_draining) {
      return;
    }
    _draining = true;
    try {
      while (true) {
        // 退避等待中的 queued 任务不被取出；全部在等待时挂一个定时器再回来。
        final now = DateTime.now();
        final waiting = _tasks.where((t) => t.state == TransferState.queued).toList();
        if (waiting.isEmpty) {
          break;
        }
        final ready = waiting.where((t) => !(t.notBefore?.isAfter(now) ?? false)).toList();
        if (ready.isEmpty) {
          final earliest = waiting.map((t) => t.notBefore!).reduce((a, b) => a.isBefore(b) ? a : b);
          _backoffTimer?.cancel();
          _backoffTimer = Timer(earliest.difference(DateTime.now()), _drain);
          break;
        }
        final next = ready.first;
        if (next.cancelRequested) {
          next.state = TransferState.canceled;
          next.notifyListeners();
          notifyListeners();
          continue;
        }
        next
          ..state = TransferState.running
          ..setDetail('');
        notifyListeners();
        try {
          await next.runner(next);
          next.state = TransferState.done;
        } on TaskCanceledException {
          next.state = TransferState.canceled;
        } on Object catch (e) {
          if (next.autoRetries < _backoffSchedule.length) {
            // 指数退避自动重试：瞬时故障（断网/服务重启）自愈，不打扰用户。
            final delay = _backoffSchedule[next.autoRetries];
            next.autoRetries++;
            next
              ..state = TransferState.queued
              ..notBefore = DateTime.now().add(delay)
              ..setDetail(
                '失败，${delay.inSeconds}s 后自动重试'
                '（${next.autoRetries}/${_backoffSchedule.length}）',
              )
              ..error = '$e';
            debugPrint('TransferQueue: auto-retry "${next.label}" in $delay');
          } else {
            next
              ..state = TransferState.failed
              ..error = '$e';
          }
        }
        next.notifyListeners();
        notifyListeners();
      }
    } finally {
      _draining = false;
    }
  }

  /// Re-queues a failed or canceled task (runner decides how to resume).
  /// Clears a pending cancel — retry is an explicit go.
  void retry(TransferTask task) {
    if (task.state != TransferState.failed && task.state != TransferState.canceled) {
      return;
    }
    task
      .._cancelRequested = false
      ..notBefore = null
      ..state = TransferState.queued
      ..error = null
      ..notifyListeners();
    notifyListeners();
    unawaited(_drain());
  }

  void clearFinished() {
    _tasks.removeWhere(
      (t) => t.state == TransferState.done || t.state == TransferState.failed || t.state == TransferState.canceled,
    );
    notifyListeners();
  }

  @override
  void dispose() {
    _backoffTimer?.cancel();
    for (final task in _tasks) {
      task.dispose();
    }
    _tasks.clear();
    super.dispose();
  }
}
