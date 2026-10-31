import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/auth/session.dart';
import '../../core/backup/backup_service.dart';
import '../../core/backup/restart.dart';
import '../../core/l10n/strings.dart';
import '../../core/providers.dart';
import '../../core/services/settings_service.dart';
import 'backup_list.dart';

class SettingsScreen extends ConsumerStatefulWidget {
  const SettingsScreen({super.key});

  @override
  ConsumerState<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends ConsumerState<SettingsScreen> {
  final _form = GlobalKey<FormState>();
  final _name = TextEditingController();
  final _address = TextEditingController();
  final _phone = TextEditingController();
  List<BackupInfo> _backups = const [];
  String? _externalFolder;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _name.dispose();
    _address.dispose();
    _phone.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final company = await ref.read(settingsServiceProvider).company();
    final external = await ref.read(backupActionsProvider).externalFolder();
    final backups = await ref.read(backupServiceProvider).list();
    if (!mounted) return;
    setState(() {
      _name.text = company.name;
      _address.text = company.address;
      _phone.text = company.phone;
      _externalFolder = external?.path;
      _backups = backups;
    });
  }

  Future<void> _refreshBackups() async {
    final backups = await ref.read(backupServiceProvider).list();
    if (mounted) setState(() => _backups = backups);
  }

  void _toast(String text) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));

  /// Runs [action] with the buttons disabled and any error shown as a toast.
  Future<void> _run(Future<void> Function() action) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await action();
    } on BackupException catch (e) {
      _toast(e.message);
    } catch (e) {
      _toast('${Strings.unexpectedError}: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _saveCompany() async {
    if (!_form.currentState!.validate()) return;
    await _run(() async {
      await ref.read(settingsServiceProvider).saveCompany(
            CompanyInfo(name: _name.text, address: _address.text, phone: _phone.text),
          );
      _toast(Strings.saved);
    });
  }

  Future<void> _backupNow() => _run(() async {
        await ref
            .read(backupActionsProvider)
            .backupNow(userId: ref.read(currentUserProvider)?.id);
        await _refreshBackups();
        _toast(Strings.backupDone);
      });

  Future<void> _chooseExternalFolder() => _run(() async {
        final path = await FilePicker.getDirectoryPath();
        if (path == null) return;
        await ref.read(backupActionsProvider).setExternalFolder(path);
        setState(() => _externalFolder = path);
      });

  Future<void> _removeExternalFolder() => _run(() async {
        await ref.read(backupActionsProvider).setExternalFolder(null);
        setState(() => _externalFolder = null);
      });

  Future<void> _restoreFromFile() async {
    final picked = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['zip'],
    );
    final path = picked?.files.single.path;
    if (path != null) await _restore(File(path));
  }

  Future<void> _restore(File zip) async {
    if (!await confirmRestore(context)) return;
    var staged = false;
    await _run(() async {
      await ref
          .read(backupActionsProvider)
          .restore(zip, userId: ref.read(currentUserProvider)?.id);
      staged = true;
    });
    if (!staged || !mounted) return;
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        content: const Text(Strings.restoreReady),
        actions: [
          FilledButton(
            onPressed: () => restartApp(ref.read(databaseProvider)),
            child: const Text(Strings.restartNow),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        Text(Strings.settings, style: theme.textTheme.headlineSmall),
        const SizedBox(height: 16),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Form(
              key: _form,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(Strings.companySection, style: theme.textTheme.titleMedium),
                  TextFormField(
                    controller: _name,
                    decoration: const InputDecoration(labelText: Strings.companyName),
                    validator: (v) =>
                        (v == null || v.trim().isEmpty) ? Strings.required : null,
                  ),
                  TextFormField(
                    controller: _address,
                    decoration: const InputDecoration(labelText: Strings.companyAddress),
                  ),
                  TextFormField(
                    controller: _phone,
                    decoration: const InputDecoration(labelText: Strings.companyPhone),
                  ),
                  const SizedBox(height: 16),
                  FilledButton(
                    onPressed: _busy ? null : _saveCompany,
                    child: const Text(Strings.save),
                  ),
                ],
              ),
            ),
          ),
        ),
        const SizedBox(height: 16),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(Strings.backupSection, style: theme.textTheme.titleMedium),
                const SizedBox(height: 8),
                const Text(Strings.backupInfo),
                const SizedBox(height: 16),
                Wrap(
                  spacing: 12,
                  runSpacing: 8,
                  children: [
                    FilledButton.icon(
                      onPressed: _busy ? null : _backupNow,
                      icon: const Icon(Icons.backup_outlined),
                      label: const Text(Strings.backupNow),
                    ),
                    OutlinedButton.icon(
                      onPressed: _busy ? null : _restoreFromFile,
                      icon: const Icon(Icons.restore),
                      label: const Text(Strings.restoreFromFile),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.usb_outlined),
                  title: const Text(Strings.externalFolder),
                  subtitle: Text(_externalFolder ?? Strings.externalFolderNone),
                  trailing: Wrap(
                    spacing: 8,
                    children: [
                      if (_externalFolder != null)
                        TextButton(
                          onPressed: _busy ? null : _removeExternalFolder,
                          child: const Text(Strings.removeFolder),
                        ),
                      OutlinedButton(
                        onPressed: _busy ? null : _chooseExternalFolder,
                        child: const Text(Strings.chooseFolder),
                      ),
                    ],
                  ),
                ),
                const Divider(),
                BackupList(
                  backups: _backups,
                  onRestore: (b) => _busy ? null : _restore(b.file),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}
