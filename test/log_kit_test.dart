import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:log_kit/log_kit.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('log_kit_facade_test_');
  });

  tearDown(() async {
    await LogKit.resetForTesting();
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  test('logs below minLevel are dropped, at/above are written', () async {
    await LogKit.init(
      LogKitConfig(
        appName: 'testapp',
        minLevel: LogLevel.warn,
        directory: tempDir.path,
        ringBufferCapacity: 10,
      ),
    );

    LogKit.d('debug message, should be dropped');
    LogKit.e('error message, should be kept');

    expect(LogKit.recentEntries.map((e) => e.message), ['error message, should be kept']);
  });

  test('a second init() call is ignored; first config wins', () async {
    await LogKit.init(
      LogKitConfig(appName: 'first', directory: tempDir.path),
    );
    await LogKit.init(
      LogKitConfig(appName: 'second', directory: '${tempDir.path}/other'),
    );

    expect(LogKit.configForTesting?.appName, 'first');
  });

  test(
    'a second concurrent init() call resolves only once the first call\'s '
    'initialization has actually finished, not immediately',
    () async {
      // Regression test: init() used to guard with a synchronous bool
      // flag and return immediately for a second caller, even while the
      // first call was still mid-flight (e.g. awaiting FileSink.init()'s
      // directory creation/cleanup). A caller doing `await LogKit.init()`
      // must be guaranteed logging is ready once that await resolves.
      // Deliberately not awaited — fire the first call into flight, then
      // immediately (synchronously) issue a second call before the first
      // has any chance to complete its async work.
      unawaited(
        LogKit.init(LogKitConfig(appName: 'first', directory: tempDir.path)),
      );
      // The second caller's own `await` must not resolve until the FIRST
      // call's full init body — including FileSink.init(), which does
      // real directory creation/cleanup I/O — has finished. Under the old
      // bool-flag guard, this would return immediately instead.
      await LogKit.init(
        LogKitConfig(appName: 'second', directory: '${tempDir.path}/other'),
      );

      expect(LogKit.configForTesting?.appName, 'first');
      expect(LogKit.logFilesDirectory, isNotNull);
      // Must not throw StateError("file logging unavailable") right here,
      // immediately after the second await — proves _dumper was already
      // set up, i.e. the full first-call init body had actually finished.
      final zip = await LogKit.dumpLogs();
      expect(await zip.exists(), isTrue);
    },
  );

  test('dumpLogs() throws before init()', () {
    expect(() => LogKit.dumpLogs(), throwsStateError);
  });

  test('dumpLogs() reflects entries written via LogKit.d/i/w/e', () async {
    await LogKit.init(
      LogKitConfig(appName: 'testapp', directory: tempDir.path),
    );

    LogKit.i('hello from LogKit');
    await LogKit.fileSinkForTesting?.flush();

    final zip = await LogKit.dumpLogs();
    expect(await zip.exists(), isTrue);
  });

  test(
    'a throwing sink cannot crash the LogKit.e()/d/i/w/v call site, and '
    'other sinks still receive the entry',
    () async {
      await LogKit.init(
        LogKitConfig(
          appName: 'testapp',
          directory: tempDir.path,
          ringBufferCapacity: 10,
        ),
      );

      LogKit.addSink(CallbackLogSink((_) => throw StateError('boom')));

      // Must not throw, even though the sink above always throws.
      LogKit.e('should survive a broken downstream sink');

      // RingBufferSink is registered before the throwing sink, but the
      // point is every *other* sink still gets the entry regardless of
      // where the broken one sits in the list.
      expect(
        LogKit.recentEntries.map((e) => e.message),
        contains('should survive a broken downstream sink'),
      );
    },
  );
}
