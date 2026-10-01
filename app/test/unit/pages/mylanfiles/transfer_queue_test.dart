import 'dart:async';

import 'package:localsend_app/pages/mylanfiles/transfer_queue.dart';
import 'package:test/test.dart';

void main() {
  group('pickTransferMode (§4.2 adaptive rule)', () {
    const mib = 1024 * 1024;
    test('median below 2 MiB → pack', () {
      expect(
        pickTransferMode([100, mib, 3 * mib]),
        TransferMode.pack,
      );
    });
    test('median at or above 2 MiB → sequential', () {
      expect(
        pickTransferMode([100, 2 * mib, 3 * mib]),
        TransferMode.sequential,
      );
    });
    test('even count uses lower middle', () {
      expect(pickTransferMode([mib, 5 * mib]), TransferMode.pack);
      expect(pickTransferMode([3 * mib, 5 * mib]), TransferMode.sequential);
    });
    test('empty and single', () {
      expect(pickTransferMode(const []), TransferMode.sequential);
      expect(pickTransferMode([1]), TransferMode.pack);
      expect(pickTransferMode([5 * mib]), TransferMode.sequential);
    });
  });

  group('TransferQueue', () {
    test('runs tasks one at a time, progress recorded', () async {
      final queue = TransferQueue();
      addTearDown(queue.dispose);
      var concurrent = 0;
      var maxConcurrent = 0;

      TransferTask makeTask(String label, List<int> chunks) {
        final seen = <int>[];
        return TransferTask(
          label: label,
          kind: TransferKind.singleFile,
          totalBytes: chunks.fold(0, (a, b) => a + b),
          runner: (task) async {
            concurrent++;
            maxConcurrent = concurrent > maxConcurrent ? concurrent : maxConcurrent;
            for (final chunk in chunks) {
              await Future<void>.delayed(const Duration(milliseconds: 5));
              task.addBytes(chunk);
              seen.add(task.receivedBytes);
            }
            concurrent--;
          },
        );
      }

      final first = makeTask('a', [10, 20, 70]);
      final second = makeTask('b', [5, 5]);
      queue
        ..enqueue(first)
        ..enqueue(second);

      await Future<void>.delayed(const Duration(milliseconds: 120));
      expect(first.state, TransferState.done);
      expect(second.state, TransferState.done);
      expect(maxConcurrent, 1, reason: 'sequential execution');
      expect(first.receivedBytes, 100);
      expect(second.receivedBytes, 10);
    });

    test('failure marks the task, queue continues, retry re-runs', () async {
      final queue = TransferQueue();
      addTearDown(queue.dispose);
      var ran = 0;

      final failing = TransferTask(
        label: 'bad',
        kind: TransferKind.singleFile,
        totalBytes: 10,
        runner: (task) async {
          ran++;
          task.addBytes(4);
          throw Exception('wire cut');
        },
      );
      final healthy = TransferTask(
        label: 'ok',
        kind: TransferKind.singleFile,
        totalBytes: 1,
        runner: (task) async {
          task.addBytes(1);
        },
      );

      queue
        ..enqueue(failing)
        ..enqueue(healthy);
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(failing.state, TransferState.failed);
      expect(failing.error, contains('wire cut'));
      expect(healthy.state, TransferState.done);

      queue.retry(failing);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(failing.state, TransferState.failed, reason: 'still failing');
      expect(ran, 2);
    });

    test('clearFinished keeps queued/running tasks', () async {
      final queue = TransferQueue();
      addTearDown(queue.dispose);
      final gate = Completer<void>();

      final running = TransferTask(
        label: 'running',
        kind: TransferKind.pack,
        totalBytes: 1,
        runner: (_) => gate.future,
      );
      final queued = TransferTask(
        label: 'queued',
        kind: TransferKind.pack,
        totalBytes: 1,
        runner: (_) async {},
      );
      final done = TransferTask(
        label: 'done',
        kind: TransferKind.pack,
        totalBytes: 1,
        runner: (_) async {},
      )..state = TransferState.done;

      queue
        ..enqueue(running)
        ..enqueue(queued)
        ..enqueue(done);
      queue.clearFinished();

      expect(queue.tasks, hasLength(2));
      expect(queue.tasks.map((t) => t.label), ['running', 'queued']);
      gate.complete();
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(queued.state, TransferState.done);
    });
  });
}
