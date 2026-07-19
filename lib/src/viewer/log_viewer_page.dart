import 'package:flutter/material.dart';

import '../log_formatter.dart';
import '../log_vault.dart';

/// A minimal in-app log viewer over `LogVault.recentEntries` (the ring
/// buffer), with a share action that calls `LogVault.shareLogs`.
///
/// This only shows entries logged on the current isolate since [init] —
/// it is a quick on-device triage tool, not a substitute for the full
/// on-disk log files that [LogVault.shareLogs] exports.
class LogViewerPage extends StatelessWidget {
  const LogViewerPage({super.key, this.formatter = const LogFormatter()});

  final LogFormatter formatter;

  @override
  Widget build(BuildContext context) {
    final entries = LogVault.recentEntries.reversed.toList(growable: false);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Logs'),
        actions: [
          IconButton(
            icon: const Icon(Icons.share),
            onPressed: () => _shareLogs(context),
          ),
        ],
      ),
      body: entries.isEmpty
          ? const Center(child: Text('No log entries yet.'))
          : ListView.builder(
              itemCount: entries.length,
              itemBuilder: (context, index) => Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 4,
                ),
                child: SelectableText(
                  formatter.format(entries[index]),
                  style: const TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 12,
                  ),
                ),
              ),
            ),
    );
  }

  Future<void> _shareLogs(BuildContext context) async {
    final directory = LogVault.logFilesDirectory;
    final hasFiles =
        directory != null &&
        await directory.exists() &&
        await directory.list().any((_) => true);
    if (!hasFiles) {
      if (!context.mounted) return;
      await showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('No log files'),
          content: const Text(
            'No log files have been written yet on this device.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('OK'),
            ),
          ],
        ),
      );
      return;
    }
    if (!context.mounted) return;
    await LogVault.shareLogs(context);
  }
}
