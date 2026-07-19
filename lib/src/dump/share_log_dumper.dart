import 'dart:developer' as developer;

import 'package:flutter/widgets.dart';
import 'package:share_plus/share_plus.dart';

import 'log_dumper.dart';

/// Thin wrapper around [LogDumper] that hands the resulting zip to the
/// platform share sheet via `share_plus`. Kept as a separate class from
/// [LogDumper] so callers with their own upload/support flow only depend
/// on the zip-building half.
class ShareLogDumper {
  ShareLogDumper(this._dumper);

  final LogDumper _dumper;

  Future<ShareResult> share(
    BuildContext context, {
    String subject = 'App logs',
    Map<String, Object?> metadata = const {},
    List<XFile> extraFiles = const [],
    Rect? sharePositionOrigin,
  }) async {
    final zipFile = await _dumper.dumpLogs(metadata: metadata);
    Rect? origin = sharePositionOrigin;
    if (origin == null) {
      if (!context.mounted) {
        throw StateError(
          'ShareLogDumper.share: context was unmounted while building the '
          'log dump; pass an explicit sharePositionOrigin to avoid needing '
          'the context after the async gap.',
        );
      }
      origin = _resolveOrigin(context);
    }
    return SharePlus.instance.share(
      ShareParams(
        files: [XFile(zipFile.path), ...extraFiles],
        subject: subject,
        sharePositionOrigin: origin,
      ),
    );
  }

  /// Best-effort resolution of the share-sheet anchor rect from [context]'s
  /// render box. Required on iPad — `share_plus` can throw/no-op without
  /// `sharePositionOrigin` there — but callers can still pass an explicit
  /// rect (e.g. the tapped button's own position) to override this.
  Rect? _resolveOrigin(BuildContext context) {
    final renderObject = context.findRenderObject();
    if (renderObject is! RenderBox || !renderObject.attached) {
      developer.log(
        'log_vault ShareLogDumper: could not resolve sharePositionOrigin '
        'from context (no attached RenderBox) — the share sheet may fail '
        'or mis-position on iPad. Pass sharePositionOrigin explicitly to '
        'avoid this.',
        name: 'log_vault',
        level: 900,
      );
      return null;
    }
    final topLeft = renderObject.localToGlobal(Offset.zero);
    return topLeft & renderObject.size;
  }
}
