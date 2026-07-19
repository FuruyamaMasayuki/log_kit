/// Controls how [FileSink] rotates and prunes log files on disk.
class LogRetentionPolicy {
  const LogRetentionPolicy({
    this.maxAgeDays = 7,
    this.maxTotalBytes = 50 * 1024 * 1024,
    this.maxFileBytes = 5 * 1024 * 1024,
  });

  /// Files whose last-modified time is older than this many days are
  /// deleted on startup.
  final int maxAgeDays;

  /// If the total size of all log files exceeds this, the oldest files
  /// (by mtime) are deleted until the directory fits the budget.
  final int maxTotalBytes;

  /// When the current day's log file would exceed this size, a new file
  /// with a numeric suffix (`log_20260101_2.log`) is started instead.
  final int maxFileBytes;
}
