import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:log_vault/log_vault.dart';

void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('log_vault_dump_test_');
  });

  tearDown(() async {
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  test('zips log files and includes a metadata.json with merged fields', () async {
    await File('${tempDir.path}/log_20260305.log').writeAsString('line one\n');
    await File('${tempDir.path}/log_20260304.log').writeAsString('line two\n');

    final dumper = LogDumper(directory: tempDir, appName: 'testapp');
    final zipFile = await dumper.dumpLogs(
      metadata: {'appVersion': '1.2.3'},
    );

    expect(await zipFile.exists(), isTrue);

    final bytes = await zipFile.readAsBytes();
    final archive = ZipDecoder().decodeBytes(bytes);
    final names = archive.files.map((f) => f.name).toSet();

    expect(names, containsAll(['log_20260305.log', 'log_20260304.log', 'metadata.json']));

    final metadataEntry = archive.files.firstWhere((f) => f.name == 'metadata.json');
    final metadata = jsonDecode(
      utf8.decode(metadataEntry.content as List<int>),
    ) as Map<String, Object?>;

    expect(metadata['appName'], 'testapp');
    expect(metadata['appVersion'], '1.2.3');
    expect(metadata['generatedAt'], isNotNull);
  });

  test(
    'does not throw when metadata contains a non-JSON-encodable value; '
    'stringifies it instead',
    () async {
      await File('${tempDir.path}/log_20260305.log').writeAsString('line\n');

      final dumper = LogDumper(directory: tempDir, appName: 'testapp');
      // DateTime is not directly JSON-encodable — the old code threw
      // JsonUnsupportedObjectError mid-dump on this.
      final buildDate = DateTime(2026, 3, 5, 12, 0, 0);
      final zipFile = await dumper.dumpLogs(
        metadata: {'buildDate': buildDate, 'appVersion': '1.2.3'},
      );

      expect(await zipFile.exists(), isTrue);

      final bytes = await zipFile.readAsBytes();
      final archive = ZipDecoder().decodeBytes(bytes);
      final metadataEntry =
          archive.files.firstWhere((f) => f.name == 'metadata.json');
      final metadata = jsonDecode(
        utf8.decode(metadataEntry.content as List<int>),
      ) as Map<String, Object?>;

      // Encodable values pass through unchanged; the DateTime is
      // best-effort stringified rather than crashing the dump.
      expect(metadata['appVersion'], '1.2.3');
      expect(metadata['buildDate'], buildDate.toString());
    },
  );

  test('only copies files matching the log_vault file name pattern', () async {
    await File('${tempDir.path}/log_20260305.log').writeAsString('line\n');
    await File('${tempDir.path}/unrelated.txt').writeAsString('noise\n');

    final dumper = LogDumper(directory: tempDir, appName: 'testapp');
    final zipFile = await dumper.dumpLogs();

    final bytes = await zipFile.readAsBytes();
    final archive = ZipDecoder().decodeBytes(bytes);
    final names = archive.files.map((f) => f.name).toSet();

    expect(names, contains('log_20260305.log'));
    expect(names, isNot(contains('unrelated.txt')));
  });

  test('calls flush before snapshotting files', () async {
    var flushed = false;
    final dumper = LogDumper(
      directory: tempDir,
      appName: 'testapp',
      flush: () async {
        flushed = true;
        // Simulate a pending write landing before the snapshot is taken.
        await File('${tempDir.path}/log_20260305.log').writeAsString('flushed line\n');
      },
    );

    final zipFile = await dumper.dumpLogs();
    expect(flushed, isTrue);

    final bytes = await zipFile.readAsBytes();
    final archive = ZipDecoder().decodeBytes(bytes);
    final logEntry = archive.files.firstWhere((f) => f.name == 'log_20260305.log');
    expect(utf8.decode(logEntry.content as List<int>), contains('flushed line'));
  });

  test('a second dumpLogs() call deletes the previous zip', () async {
    await File('${tempDir.path}/log_20260305.log').writeAsString('line\n');

    final dumper = LogDumper(directory: tempDir, appName: 'testapp');
    final firstZip = await dumper.dumpLogs();
    expect(await firstZip.exists(), isTrue);

    final secondZip = await dumper.dumpLogs();
    expect(await secondZip.exists(), isTrue);
    expect(await firstZip.exists(), isFalse);
  });

  test(
    'concurrent dumpLogs() calls are serialized — a later call never '
    'deletes an earlier call\'s in-progress zip',
    () async {
      await File(
        '${tempDir.path}/log_20260305.log',
      ).writeAsString('line\n');

      final dumper = LogDumper(directory: tempDir, appName: 'testapp');

      // Both calls start "concurrently" (neither is awaited before the
      // second is issued). Without serialization, the second call's
      // disposeLastDump() step could delete the first call's temp
      // directory while it's still being read/zipped.
      final results = await Future.wait([
        dumper.dumpLogs(),
        dumper.dumpLogs(),
      ]);

      // Both must complete successfully, and since they're serialized,
      // only the last one's zip should still exist afterward.
      expect(await results[0].exists(), isFalse);
      expect(await results[1].exists(), isTrue);
    },
  );

  test('disposeLastDump() deletes the most recent zip on demand', () async {
    await File('${tempDir.path}/log_20260305.log').writeAsString('line\n');

    final dumper = LogDumper(directory: tempDir, appName: 'testapp');
    final zipFile = await dumper.dumpLogs();
    expect(await zipFile.exists(), isTrue);

    await dumper.disposeLastDump();
    expect(await zipFile.exists(), isFalse);
  });

  test('produces an empty-of-logs zip (metadata only) when the directory has no files', () async {
    final dumper = LogDumper(directory: tempDir, appName: 'testapp');
    final zipFile = await dumper.dumpLogs();

    final bytes = await zipFile.readAsBytes();
    final archive = ZipDecoder().decodeBytes(bytes);
    expect(archive.files.map((f) => f.name), ['metadata.json']);
  });
}
