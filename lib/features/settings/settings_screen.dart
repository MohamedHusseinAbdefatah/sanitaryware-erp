import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:printing/printing.dart';

import '../../core/auth/session.dart';
import '../../core/backup/backup_service.dart';
import '../../core/backup/restart.dart';
import '../../core/l10n/strings.dart';
import '../../core/printing/pdf_fonts.dart';
import '../../core/printing/test_page.dart';
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
  String? _logoPath;
  bool _busy = false;
  bool _allowNegativeStock = false;
  bool _countPendingCheques = false;

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
    final settings = ref.read(settingsServiceProvider);
    final rules = (
      await settings.getBool(SettingKey.allowNegativeStock),
      await settings.getBool(SettingKey.countPendingCheques),
    );
    final logo = await settings.get(SettingKey.companyLogo);
    if (!mounted) return;
    setState(() {
      _logoPath = (logo == null || logo.isEmpty) ? null : logo;
      _name.text = company.name;
      _address.text = company.address;
      _phone.text = company.phone;
      _externalFolder = external?.path;
      _backups = backups;
      _allowNegativeStock = rules.$1;
      _countPendingCheques = rules.$2;
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

  /// Copies the chosen image into the data folder (next to the database),
  /// so it survives if the original file is moved and is in every backup
  /// folder's neighbourhood.
  Future<void> _chooseLogo() => _run(() async {
        final picked = await FilePicker.pickFiles(
          type: FileType.custom,
          allowedExtensions: ['png', 'jpg', 'jpeg'],
        );
        final source = picked?.files.single.path;
        if (source == null) return;
        final dataDir = ref.read(databaseFileProvider).parent;
        final ext = source.split('.').last.toLowerCase();
        final target = File('${dataDir.path}${Platform.pathSeparator}logo.$ext');
        await File(source).copy(target.path);
        await ref.read(settingsServiceProvider).set(SettingKey.companyLogo, target.path);
        imageCache.clear();
        setState(() => _logoPath = target.path);
      });

  Future<void> _removeLogo() => _run(() async {
        await ref.read(settingsServiceProvider).set(SettingKey.companyLogo, '');
        setState(() => _logoPath = null);
      });

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

  /// Opens the Windows print dialog (with "Microsoft Print to PDF" as an
  /// option) for the Arabic test page.
  Future<void> _printTestPage() => _run(() async {
        final fonts = await PdfFonts.load();
        final company = await ref.read(settingsServiceProvider).company();
        await Printing.layoutPdf(
          name: Strings.printTestPage,
          onLayout: (_) => buildTestPage(
            fonts: fonts,
            company: company,
            printedAt: DateTime.now(),
          ),
        );
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
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(Strings.rulesSection, style: theme.textTheme.titleMedium),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text(Strings.allowNegativeStock),
                  subtitle: const Text(Strings.allowNegativeStockHint),
                  value: _allowNegativeStock,
                  onChanged: _busy
                      ? null
                      : (v) => _run(() async {
                            await ref.read(settingsServiceProvider).setBool(SettingKey.allowNegativeStock, v);
                            setState(() => _allowNegativeStock = v);
                          }),
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text(Strings.countPendingCheques),
                  subtitle: const Text(Strings.countPendingChequesHint),
                  value: _countPendingCheques,
                  onChanged: _busy
                      ? null
                      : (v) => _run(() async {
                            await ref.read(settingsServiceProvider).setBool(SettingKey.countPendingCheques, v);
                            setState(() => _countPendingCheques = v);
                          }),
                ),
              ],
            ),
          ),
        ),
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
                  Row(
                    children: [
                      Container(
                        width: 72,
                        height: 72,
                        decoration: BoxDecoration(border: Border.all(color: theme.colorScheme.outlineVariant)),
                        child: _logoPath != null && File(_logoPath!).existsSync()
                            ? Image.file(File(_logoPath!), fit: BoxFit.contain)
                            : const Icon(Icons.image_outlined),
                      ),
                      const SizedBox(width: 12),
                      OutlinedButton(
                        onPressed: _busy ? null : _chooseLogo,
                        child: const Text(Strings.chooseLogo),
                      ),
                      if (_logoPath != null) ...[
                        const SizedBox(width: 8),
                        TextButton(onPressed: _busy ? null : _removeLogo, child: const Text(Strings.removeFolder)),
                      ],
                    ],
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
                Text(Strings.printingSection, style: theme.textTheme.titleMedium),
                const SizedBox(height: 8),
                const Text(Strings.printTestInfo),
                const SizedBox(height: 16),
                OutlinedButton.icon(
                  onPressed: _busy ? null : _printTestPage,
                  icon: const Icon(Icons.print_outlined),
                  label: const Text(Strings.printTestPage),
                ),
              ],
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
