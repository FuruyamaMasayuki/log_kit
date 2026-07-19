import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:log_kit/log_kit.dart';

LogEntry _entry(String message) => LogEntry(
  timestamp: DateTime(2026, 1, 1),
  level: LogLevel.debug,
  message: message,
);

void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('log_kit_test_');
  });

  tearDown(() async {
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  test('writes today\'s entries to log_YYYYMMDD.log', () async {
    final sink = FileSink(
      directory: tempDir,
      formatter: const LogFormatter(),
      retention: const LogRetentionPolicy(),
      fileLoggingEnabled: () => true,
      now: () => DateTime(2026, 3, 5),
    );
    await sink.init();
    sink.write(_entry('hello'));
    await sink.flush();

    final file = File('${tempDir.path}/log_20260305.log');
    expect(await file.exists(), isTrue);
    expect(await file.readAsString(), contains('hello'));
  });

  test('rotates to a new file when the day changes', () async {
    var current = DateTime(2026, 3, 5, 23, 59);
    final sink = FileSink(
      directory: tempDir,
      formatter: const LogFormatter(),
      retention: const LogRetentionPolicy(),
      fileLoggingEnabled: () => true,
      now: () => current,
    );
    await sink.init();
    sink.write(_entry('day one'));
    await sink.flush();

    current = DateTime(2026, 3, 6, 0, 1);
    sink.write(_entry('day two'));
    await sink.flush();

    expect(
      await File('${tempDir.path}/log_20260305.log').exists(),
      isTrue,
    );
    expect(
      await File('${tempDir.path}/log_20260306.log').exists(),
      isTrue,
    );
  });

  test('rotates within a day once maxFileBytes is exceeded', () async {
    final sink = FileSink(
      directory: tempDir,
      formatter: const LogFormatter(),
      retention: const LogRetentionPolicy(maxFileBytes: 40),
      fileLoggingEnabled: () => true,
      now: () => DateTime(2026, 3, 5),
    );
    await sink.init();

    for (var i = 0; i < 5; i++) {
      sink.write(_entry('entry number $i, padded to be long enough'));
    }
    await sink.flush();

    final files = await tempDir
        .list()
        .where((e) => e is File)
        .cast<File>()
        .toList();
    expect(files.length, greaterThan(1));
    expect(
      files.any((f) => f.path.endsWith('log_20260305_2.log')),
      isTrue,
    );
  });

  test('startup cleanup deletes files older than maxAgeDays', () async {
    final oldFile = File('${tempDir.path}/log_20250101.log')
      ..createSync();
    await oldFile.setLastModified(DateTime(2025, 1, 1));

    final sink = FileSink(
      directory: tempDir,
      formatter: const LogFormatter(),
      retention: const LogRetentionPolicy(maxAgeDays: 7),
      fileLoggingEnabled: () => true,
      now: () => DateTime(2026, 3, 5),
    );
    await sink.init();

    expect(await oldFile.exists(), isFalse);
  });

  test(
    'startup cleanup deletes oldest-by-mtime files over maxTotalBytes, '
    'not by filename lexical order',
    () async {
      // Filenames are chosen so lexical order would pick the wrong file:
      // 'log_20260101_10.log' sorts before 'log_20260101_2.log' as a
      // string, but by mtime file "_2" is older and should be deleted
      // first.
      final fileTen = File('${tempDir.path}/log_20260101_10.log')
        ..writeAsStringSync('x' * 100);
      await fileTen.setLastModified(DateTime(2026, 1, 3));

      final fileTwo = File('${tempDir.path}/log_20260101_2.log')
        ..writeAsStringSync('x' * 100);
      await fileTwo.setLastModified(DateTime(2026, 1, 1));

      final sink = FileSink(
        directory: tempDir,
        formatter: const LogFormatter(),
        retention: const LogRetentionPolicy(
          maxAgeDays: 365,
          maxTotalBytes: 150,
        ),
        fileLoggingEnabled: () => true,
        now: () => DateTime(2026, 1, 4),
      );
      await sink.init();

      expect(await fileTwo.exists(), isFalse);
      expect(await fileTen.exists(), isTrue);
    },
  );

  test(
    'rotation sizing uses UTF-8 byte length, not UTF-16 code units',
    () async {
      // Each character below is 3 bytes in UTF-8 but 1 UTF-16 code unit.
      // If sizing used String.length, ~14 of these characters would be
      // needed to exceed maxFileBytes: 40; using UTF-8 bytes, far fewer
      // are needed, so rotation must happen well before 14 writes.
      final sink = FileSink(
        directory: tempDir,
        formatter: const LogFormatter(),
        retention: const LogRetentionPolicy(maxFileBytes: 40),
        fileLoggingEnabled: () => true,
        now: () => DateTime(2026, 3, 5),
      );
      await sink.init();

      for (var i = 0; i < 5; i++) {
        sink.write(_entry('日本語のログメッセージです $i'));
      }
      await sink.flush();

      final files = await tempDir
          .list()
          .where((e) => e is File)
          .cast<File>()
          .toList();
      expect(
        files.any((f) => f.path.endsWith('log_20260305_2.log')),
        isTrue,
      );
    },
  );

  test('write() is a no-op when fileLoggingEnabled returns false', () async {
    final sink = FileSink(
      directory: tempDir,
      formatter: const LogFormatter(),
      retention: const LogRetentionPolicy(),
      fileLoggingEnabled: () => false,
      now: () => DateTime(2026, 3, 5),
    );
    await sink.init();
    sink.write(_entry('should not be written'));
    await sink.flush();

    expect(await tempDir.list().toList(), isEmpty);
  });

  test(
    'two FileSinks racing startup cleanup over the same directory do not '
    'throw when both try to delete the same expired file',
    () async {
      final oldFile = File('${tempDir.path}/log_20250101.log')..createSync();
      await oldFile.setLastModified(DateTime(2025, 1, 1));

      FileSink makeSink() => FileSink(
        directory: tempDir,
        formatter: const LogFormatter(),
        retention: const LogRetentionPolicy(maxAgeDays: 1),
        fileLoggingEnabled: () => true,
        now: () => DateTime(2026, 3, 5),
      );

      // Both sinks list the same expired file before either deletes it,
      // then both attempt File.delete() on it — the second delete would
      // throw PathNotFoundException without the fix.
      await Future.wait([makeSink().init(), makeSink().init()]);

      expect(await oldFile.exists(), isFalse);
    },
  );
}
