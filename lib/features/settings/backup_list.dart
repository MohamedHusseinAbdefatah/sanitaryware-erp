import 'package:flutter/material.dart';

import '../../core/backup/backup_service.dart';
import '../../core/dates.dart';
import '../../core/l10n/strings.dart';

String backupReasonLabel(String reason) => switch (reason) {
      BackupReason.manual => Strings.backupReasonManual,
      BackupReason.onClose => Strings.backupReasonAuto,
      BackupReason.beforeMigration => Strings.backupReasonMigration,
      BackupReason.beforeRestore => Strings.backupReasonRestore,
      BackupReason.beforeReset => Strings.backupReasonReset,
      _ => reason,
    };

String _size(int bytes) => bytes < 1024 * 1024
    ? '${(bytes / 1024).ceil()} KB'
    : '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';

/// The backups in the backup folder, newest first, each with a restore button.
class BackupList extends StatelessWidget {
  const BackupList({super.key, required this.backups, required this.onRestore});

  final List<BackupInfo> backups;
  final void Function(BackupInfo) onRestore;

  @override
  Widget build(BuildContext context) {
    if (backups.isEmpty) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 12),
        child: Text(Strings.noBackups),
      );
    }
    return Column(
      children: [
        for (final b in backups)
          ListTile(
            dense: true,
            leading: const Icon(Icons.archive_outlined),
            title: Text(formatDateTime(b.time)),
            subtitle: Text('${backupReasonLabel(b.reason)} · ${_size(b.sizeBytes)}'),
            trailing: TextButton(
              onPressed: () => onRestore(b),
              child: const Text(Strings.restore),
            ),
          ),
      ],
    );
  }
}

/// Asks before replacing all data. Returns true if the person confirmed.
Future<bool> confirmRestore(BuildContext context) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text(Strings.restoreConfirmTitle),
      content: const Text(Strings.restoreConfirmBody),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text(Strings.cancel),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, true),
          child: const Text(Strings.restore),
        ),
      ],
    ),
  );
  return ok ?? false;
}
