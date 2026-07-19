import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:archive/archive_io.dart';
import 'package:path/path.dart' as p;

import '../sinks/file_sink.dart';

/// Builds a zip archive of the log directory (+ `metadata.json`) with no UI
/// or `share_plus` dependency, so callers with their own upload/support
/// flow can use it standalone (`LogVault.dumpLogs`); `shareLogs` layers a
/// share-sheet call on top of this.
///
/// Reuse a single [LogDumper] instance across calls (as `LogVault` does)
/// rather than constructing a new one per dump — [dumpLogs] deletes the
/// *previous* dump produced by the same instance before building a new
/// one, which bounds leaked temp files to at most one stale zip rather
/// than accumulating one per call. Call [disposeLastDump] once the caller
/// is done with a zip (e.g. after an upload completes) to reclaim it
/// immediately instead of waiting for the next dump.
class LogDumper {
  LogDumper({required this.directory, required this.appName, this.flush});

  final Directory directory;
  final String appName;

  /// Awaited before snapshotting files, so writes already queued when
  /// [dumpLogs] is called land in the dump instead of racing the zip step.
  /// Typically `FileSink.flush`.
  final Future<void> Function()? flush;

  Directory? _lastTempRoot;

  // Serializes dumpLogs()/disposeLastDump() calls on this instance (FIFO)
  // so a second dumpLogs() call — e.g. a double-tapped share button, with
  // zipping taking multiple seconds for a large log dir — can't delete the
  // temp directory a first, still-in-progress call is reading from. See
  // `_enqueue`.
  Future<void> _queue = Future<void>.value();

  Future<T> _enqueue<T>(Future<T> Function() action) {
    final result = _queue.then((_) => action());
    // Keep the queue itself always resolving (even if this action threw)
    // so one failed dump doesn't wedge every dump after it.
    _queue = result.then((_) {}, onError: (_) {});
    return result;
  }

  /// Flushes pending writes, copies the current log files into a temp
  /// snapshot directory, writes `metadata.json` alongside them, then zips
  /// the snapshot on a background isolate. Returns the created zip [File].
  ///
  /// Snapshotting before zipping means a log file actively being appended
  /// to by `FileSink` is never read mid-write by the zip step. There is a
  /// narrow window between [flush] resolving and this method's copy loop
  /// reaching a given file where a *new* write (issued after [dumpLogs] was
  /// called) can still land in — or be excluded from — that file; this is
  /// benign (no corruption, just an inclusion race for that one line) but
  /// is not a hard guarantee against it.
  ///
  /// Concurrent calls on the same [LogDumper] instance are queued and run
  /// one at a time, in call order — see [_enqueue].
  Future<File> dumpLogs({Map<String, Object?> metadata = const {}}) {
    return _enqueue(() => _dumpLogsImpl(metadata: metadata));
  }

  Future<File> _dumpLogsImpl({Map<String, Object?> metadata = const {}}) async {
    await flush?.call();
    await _disposeLastDumpImpl();

    final tempRoot = await Directory.systemTemp.createTemp('log_vault_dump_');
    _lastTempRoot = tempRoot;
    final snapshotDir = Directory(p.join(tempRoot.path, 'logs'));
    await snapshotDir.create(recursive: true);

    try {
      if (await directory.exists()) {
        await for (final entity in directory.list()) {
          if (entity is File &&
              FileSink.fileNamePattern.hasMatch(p.basename(entity.path))) {
            await entity.copy(
              p.join(snapshotDir.path, p.basename(entity.path)),
            );
          }
        }
      }

      final generatedAt = DateTime.now().toIso8601String();
      final fullMetadata = <String, Object?>{
        'appName': appName,
        'generatedAt': generatedAt,
        ...metadata,
      };
      final metadataFile = File(p.join(snapshotDir.path, 'metadata.json'));
      await metadataFile.writeAsString(
        // `metadata` is public API typed `Map<String, Object?>`, so a
        // caller can pass a value JSON can't encode (DateTime, Duration, a
        // domain object, ...). `toEncodable` stringifies anything the
        // encoder doesn't understand rather than throwing mid-dump — a
        // best-effort metadata field must never be the thing that fails a
        // log export.
        JsonEncoder.withIndent('  ', (Object? value) => value.toString())
            .convert(fullMetadata),
      );

      final safeTimestamp = generatedAt.replaceAll(RegExp('[:.]'), '-');
      final outputPath = p.join(
        tempRoot.path,
        '${appName}_logs_$safeTimestamp.zip',
      );

      // archive's ZipFileEncoder is synchronous and can take a noticeable
      // amount of time for a directory near maxTotalBytes (default 50MB);
      // Isolate.run keeps that off the UI thread. Only primitive values
      // cross the isolate boundary, so path_provider/plugin calls must
      // happen before this point, not inside `_zipDirectory`.
      await Isolate.run(() => _zipDirectory(snapshotDir.path, outputPath));

      return File(outputPath);
    } finally {
      if (await snapshotDir.exists()) {
        await snapshotDir.delete(recursive: true);
      }
    }
  }

  /// Deletes the zip (and its temp directory) produced by the previous
  /// [dumpLogs] call, if any and if it still exists. Safe to call
  /// unconditionally, including when no dump has been produced yet.
  ///
  /// Queued behind any in-progress [dumpLogs] call on this instance (see
  /// [_enqueue]), so this can't delete a zip out from under a dump that's
  /// still being built.
  Future<void> disposeLastDump() => _enqueue(_disposeLastDumpImpl);

  Future<void> _disposeLastDumpImpl() async {
    final previous = _lastTempRoot;
    _lastTempRoot = null;
    if (previous != null && await previous.exists()) {
      await previous.delete(recursive: true);
    }
  }
}

Future<void> _zipDirectory(String sourceDirPath, String outputZipPath) async {
  final encoder = ZipFileEncoder();
  encoder.create(outputZipPath);
  await encoder.addDirectory(Directory(sourceDirPath), includeDirName: false);
  await encoder.close();
}
