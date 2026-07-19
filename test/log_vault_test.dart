import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:log_vault/log_vault.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('log_vault_facade_test_');
  });

  tearDown(() async {
    await LogVault.resetForTesting();
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  test('logs below minLevel are dropped, at/above are written', () async {
    await LogVault.init(
      LogVaultConfig(
        appName: 'testapp',
        minLevel: LogLevel.warn,
        directory: tempDir.path,
        ringBufferCapacity: 10,
      ),
    );

    LogVault.d('debug message, should be dropped');
    LogVault.e('error message, should be kept');

    expect(LogVault.recentEntries.map((e) => e.message), ['error message, should be kept']);
  });

  test('a second init() call is ignored; first config wins', () async {
    await LogVault.init(
      LogVaultConfig(appName: 'first', directory: tempDir.path),
    );
    await LogVault.init(
      LogVaultConfig(appName: 'second', directory: '${tempDir.path}/other'),
    );

    expect(LogVault.configForTesting?.appName, 'first');
  });

  test(
    'a second concurrent init() call resolves only once the first call\'s '
    'initialization has actually finished, not immediately',
    () async {
      // Regression test: init() used to guard with a synchronous bool
      // flag and return immediately for a second caller, even while the
      // first call was still mid-flight (e.g. awaiting FileSink.init()'s
      // directory creation/cleanup). A caller doing `await LogVault.init()`
      // must be guaranteed logging is ready once that await resolves.
      // Deliberately not awaited — fire the first call into flight, then
      // immediately (synchronously) issue a second call before the first
      // has any chance to complete its async work.
      unawaited(
        LogVault.init(LogVaultConfig(appName: 'first', directory: tempDir.path)),
      );
      // The second caller's own `await` must not resolve until the FIRST
      // call's full init body — including FileSink.init(), which does
      // real directory creation/cleanup I/O — has finished. Under the old
      // bool-flag guard, this would return immediately instead.
      await LogVault.init(
        LogVaultConfig(appName: 'second', directory: '${tempDir.path}/other'),
      );

      expect(LogVault.configForTesting?.appName, 'first');
      expect(LogVault.logFilesDirectory, isNotNull);
      // Must not throw StateError("file logging unavailable") right here,
      // immediately after the second await — proves _dumper was already
      // set up, i.e. the full first-call init body had actually finished.
      final zip = await LogVault.dumpLogs();
      expect(await zip.exists(), isTrue);
    },
  );

  test('dumpLogs() throws before init()', () {
    expect(() => LogVault.dumpLogs(), throwsStateError);
  });

  test('dumpLogs() reflects entries written via LogVault.d/i/w/e', () async {
    await LogVault.init(
      LogVaultConfig(appName: 'testapp', directory: tempDir.path),
    );

    LogVault.i('hello from LogVault');
    await LogVault.fileSinkForTesting?.flush();

    final zip = await LogVault.dumpLogs();
    expect(await zip.exists(), isTrue);
  });

  test(
    'a throwing sink cannot crash the LogVault.e()/d/i/w/v call site, and '
    'other sinks still receive the entry',
    () async {
      await LogVault.init(
        LogVaultConfig(
          appName: 'testapp',
          directory: tempDir.path,
          ringBufferCapacity: 10,
        ),
      );

      LogVault.addSink(CallbackLogSink((_) => throw StateError('boom')));

      // Must not throw, even though the sink above always throws.
      LogVault.e('should survive a broken downstream sink');

      // RingBufferSink is registered before the throwing sink, but the
      // point is every *other* sink still gets the entry regardless of
      // where the broken one sits in the list.
      expect(
        LogVault.recentEntries.map((e) => e.message),
        contains('should survive a broken downstream sink'),
      );
    },
  );
}
