import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:io';

import 'package:path/path.dart' as p;

import '../log_entry.dart';
import '../log_formatter.dart';
import '../log_retention_policy.dart';
import 'log_sink.dart';

/// Writes entries to daily, size-rotated log files under [directory]:
/// `log_YYYYMMDD.log`, then `log_YYYYMMDD_2.log`, `log_YYYYMMDD_3.log`, ...
/// once the current file exceeds `retention.maxFileBytes`.
///
/// Writes within this isolate are serialized through a `Future` chain.
/// Appends across multiple isolates/processes rely on the OS append (`O_APPEND`)
/// being atomic per `write()` syscall — do not assume a single log *line* is
/// atomic if it is written via multiple separate write calls.
class FileSink implements LogSink {
  FileSink({
    required this.directory,
    required LogFormatter formatter,
    required LogRetentionPolicy retention,
    required bool Function() fileLoggingEnabled,
    DateTime Function() now = DateTime.now,
  }) : _formatter = formatter,
       _retention = retention,
       _fileLoggingEnabled = fileLoggingEnabled,
       _now = now;

  final Directory directory;
  final LogFormatter _formatter;
  final LogRetentionPolicy _retention;
  final bool Function() _fileLoggingEnabled;

  /// Injectable clock — tests use this to simulate day rollover without
  /// waiting on the real clock.
  final DateTime Function() _now;

  Future<void> _writeChain = Future<void>.value();
  File? _currentFile;
  String? _currentDateKey;
  int _currentSuffix = 1;

  /// Matches file names this sink produces, e.g. `log_20260305.log` or
  /// `log_20260305_2.log`. Exposed so `LogDumper` only snapshots log files
  /// even if `directory` is ever pointed at a shared/non-dedicated folder.
  static final RegExp fileNamePattern = RegExp(r'^log_(\d{8})(?:_(\d+))?\.log$');

  /// Creates the directory if needed and prunes files per [_retention].
  /// Must be called once before the first [write].
  Future<void> init() async {
    if (!_fileLoggingEnabled()) return;
    await directory.create(recursive: true);
    await _cleanup();
  }

  @override
  void write(LogEntry entry) {
    if (!_fileLoggingEnabled()) return;
    final line = '${_formatter.format(entry)}\n';
    // Rotation sizing must use UTF-8 byte length, not String.length (UTF-16
    // code units) — Japanese text and emoji are 1 unit but 3-4 bytes, which
    // would otherwise let maxFileBytes be under-enforced by up to ~3x.
    final bytes = utf8.encode(line);
    _writeChain = _writeChain
        .then((_) => _appendBytes(bytes))
        .catchError((Object error, StackTrace stackTrace) {
          developer.log(
            'log_kit FileSink write failed: $error',
            name: 'log_kit',
            level: 1000,
            stackTrace: stackTrace,
          );
        });
  }

  /// Waits for all writes issued so far (on this isolate) to complete.
  /// Used by `LogDumper` before snapshotting files for a zip export.
  Future<void> flush() => _writeChain;

  Future<void> _appendBytes(List<int> bytes) async {
    final file = await _resolveCurrentFile(bytes.length);
    await file.writeAsBytes(bytes, mode: FileMode.append, flush: false);
  }

  Future<File> _resolveCurrentFile(int incomingBytes) async {
    final dateKey = _formatDate(_now());
    if (_currentDateKey != dateKey) {
      _currentDateKey = dateKey;
      _currentSuffix = await _highestSuffixForDate(dateKey);
      _currentFile = _fileFor(dateKey, _currentSuffix);
    }

    var file = _currentFile!;
    final existingLength = await file.exists() ? await file.length() : 0;
    if (existingLength + incomingBytes > _retention.maxFileBytes) {
      _currentSuffix += 1;
      file = _fileFor(dateKey, _currentSuffix);
      _currentFile = file;
    }
    return file;
  }

  Future<int> _highestSuffixForDate(String dateKey) async {
    if (!await directory.exists()) return 1;
    var maxSuffix = 0;
    await for (final entity in directory.list()) {
      if (entity is! File) continue;
      final match = fileNamePattern.firstMatch(p.basename(entity.path));
      if (match == null || match.group(1) != dateKey) continue;
      final suffix = int.tryParse(match.group(2) ?? '1') ?? 1;
      if (suffix > maxSuffix) maxSuffix = suffix;
    }
    return maxSuffix == 0 ? 1 : maxSuffix;
  }

  File _fileFor(String dateKey, int suffix) {
    final name = suffix <= 1 ? 'log_$dateKey.log' : 'log_${dateKey}_$suffix.log';
    return File(p.join(directory.path, name));
  }

  static String _formatDate(DateTime dt) {
    String two(int n) => n.toString().padLeft(2, '0');
    return '${dt.year}${two(dt.month)}${two(dt.day)}';
  }

  // Another isolate/process running its own FileSink over the same
  // directory can delete a file between when this method lists/stats it
  // and when it tries to act on it (e.g. two isolates both calling
  // LogKit.init() around the same time). Every per-file operation below is
  // therefore best-effort: a file that's already gone is treated as
  // "already cleaned up" rather than an error, so one isolate's cleanup
  // can never fail the other's (or this one's own) `init()`.
  Future<void> _cleanup() async {
    if (!await directory.exists()) return;

    final candidates = <File>[];
    try {
      await for (final entity in directory.list()) {
        if (entity is File &&
            fileNamePattern.hasMatch(p.basename(entity.path))) {
          candidates.add(entity);
        }
      }
    } on FileSystemException catch (error, stackTrace) {
      _logCleanupFailure('listing $directory', error, stackTrace);
      return;
    }

    final now = _now();
    final kept = <({File file, FileStat stat})>[];
    for (final file in candidates) {
      try {
        final stat = await file.stat();
        if (stat.type == FileSystemEntityType.notFound) continue;
        final ageDays = now.difference(stat.modified).inDays;
        if (ageDays >= _retention.maxAgeDays) {
          await file.delete();
        } else {
          kept.add((file: file, stat: stat));
        }
      } on FileSystemException catch (error, stackTrace) {
        _logCleanupFailure('pruning ${file.path}', error, stackTrace);
      }
    }

    // Oldest-first by mtime, NOT filename — filename lexical order breaks
    // once a day has a double-digit suffix (log_..._10.log < log_..._2.log).
    kept.sort((a, b) => a.stat.modified.compareTo(b.stat.modified));

    var total = kept.fold<int>(0, (sum, e) => sum + e.stat.size);
    var i = 0;
    while (total > _retention.maxTotalBytes && i < kept.length) {
      total -= kept[i].stat.size;
      try {
        await kept[i].file.delete();
      } on FileSystemException catch (error, stackTrace) {
        _logCleanupFailure('deleting ${kept[i].file.path}', error, stackTrace);
      }
      i++;
    }
  }

  void _logCleanupFailure(String what, Object error, StackTrace stackTrace) {
    developer.log(
      'log_kit FileSink startup cleanup: $what failed, skipping — $error',
      name: 'log_kit',
      level: 900,
      stackTrace: stackTrace,
    );
  }

  @override
  Future<void> dispose() => flush();
}
