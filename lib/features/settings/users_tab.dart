import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/auth/auth_service.dart';
import '../../core/auth/session.dart';
import '../../core/db/database.dart';
import '../../core/l10n/strings.dart';
import '../../core/providers.dart';
import '../../core/widgets/data_list.dart';
import '../../core/widgets/feedback.dart';

class UsersTab extends ConsumerWidget {
  const UsersTab({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final users = ref.watch(_usersProvider);
    final me = ref.watch(currentUserProvider);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 16, 24, 12),
          child: Align(
            alignment: AlignmentDirectional.centerEnd,
            child: FilledButton.icon(
              onPressed: () => showDialog<void>(context: context, builder: (_) => const _UserDialog()),
              icon: const Icon(Icons.person_add_alt),
              label: const Text(Strings.newUser),
            ),
          ),
        ),
        Expanded(
          child: users.when(
            loading: () => const Center(child: CircularProgressIndicator()),
            error: (e, _) => Center(child: Text('$e')),
            data: (list) => DataList<User>(
              rows: list,
              onTap: (u) => showDialog<void>(context: context, builder: (_) => _UserDialog(existing: u)),
              trailing: (u) => IconButton(
                tooltip: Strings.resetPassword,
                icon: const Icon(Icons.key_outlined),
                onPressed: () => showDialog<void>(context: context, builder: (_) => _PasswordDialog(user: u)),
              ),
              columns: [
                DataListColumn(Strings.fullName, flex: 3, (u) => Text(u.id == me?.id ? '${u.fullName} (${Strings.you})' : u.fullName)),
                DataListColumn(Strings.username, flex: 2, (u) => Text(u.username, textDirection: TextDirection.ltr)),
                DataListColumn(Strings.role, numeric: true, (u) => Text(u.isAdmin ? Strings.roleAdmin : Strings.roleCashier)),
                DataListColumn(Strings.status, numeric: true, (u) => Text(u.isActive ? Strings.active : Strings.inactive)),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _UserDialog extends ConsumerStatefulWidget {
  const _UserDialog({this.existing});

  final User? existing;

  @override
  ConsumerState<_UserDialog> createState() => _UserDialogState();
}

class _UserDialogState extends ConsumerState<_UserDialog> {
  final _form = GlobalKey<FormState>();
  late final _name = TextEditingController(text: widget.existing?.fullName);
  final _username = TextEditingController();
  final _password = TextEditingController();
  late String _role = widget.existing?.role ?? UserRole.cashier;
  late bool _active = widget.existing?.isActive ?? true;

  @override
  void dispose() {
    _name.dispose();
    _username.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (!_form.currentState!.validate()) return;
    final auth = ref.read(authServiceProvider);
    final me = ref.read(currentUserProvider)!;
    final u = widget.existing;
    final ok = await runGuarded(context, () async {
      if (u == null) {
        await auth.addUser(
          fullName: _name.text,
          username: _username.text,
          password: _password.text,
          role: _role,
          by: me,
        );
      } else {
        await auth.updateUser(u.id, fullName: _name.text, role: _role, isActive: _active, by: me);
      }
      return true;
    });
    if (ok == true && mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final isNew = widget.existing == null;
    return AlertDialog(
      title: Text(isNew ? Strings.newUser : '${Strings.edit}: ${widget.existing!.username}'),
      content: SizedBox(
        width: 420,
        child: Form(
          key: _form,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextFormField(
                controller: _name,
                autofocus: true,
                decoration: const InputDecoration(labelText: Strings.fullName),
                validator: (v) => (v ?? '').trim().isEmpty ? Strings.required : null,
              ),
              if (isNew) ...[
                TextFormField(
                  controller: _username,
                  decoration: const InputDecoration(labelText: Strings.username),
                  validator: (v) => (v ?? '').trim().isEmpty ? Strings.required : null,
                ),
                TextFormField(
                  controller: _password,
                  obscureText: true,
                  decoration: const InputDecoration(labelText: Strings.password),
                  validator: (v) => (v ?? '').length < AuthService.minPasswordLength ? Strings.passwordTooShort : null,
                ),
              ],
              const SizedBox(height: 12),
              SegmentedButton<String>(
                segments: const [
                  ButtonSegment(value: UserRole.cashier, label: Text(Strings.roleCashier)),
                  ButtonSegment(value: UserRole.admin, label: Text(Strings.roleAdmin)),
                ],
                selected: {_role},
                onSelectionChanged: (s) => setState(() => _role = s.single),
              ),
              const SizedBox(height: 4),
              Text(
                _role == UserRole.admin ? Strings.adminRights : Strings.cashierRights,
                style: Theme.of(context).textTheme.bodySmall,
              ),
              if (!isNew)
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text(Strings.active),
                  subtitle: const Text(Strings.inactiveUserHint),
                  value: _active,
                  onChanged: (v) => setState(() => _active = v),
                ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text(Strings.cancel)),
        FilledButton(onPressed: _save, child: const Text(Strings.save)),
      ],
    );
  }
}

class _PasswordDialog extends ConsumerStatefulWidget {
  const _PasswordDialog({required this.user});

  final User user;

  @override
  ConsumerState<_PasswordDialog> createState() => _PasswordDialogState();
}

class _PasswordDialogState extends ConsumerState<_PasswordDialog> {
  final _form = GlobalKey<FormState>();
  final _password = TextEditingController();
  final _confirm = TextEditingController();

  @override
  void dispose() {
    _password.dispose();
    _confirm.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (!_form.currentState!.validate()) return;
    final ok = await runGuarded(context, () async {
      await ref
          .read(authServiceProvider)
          .resetPassword(widget.user.id, _password.text, by: ref.read(currentUserProvider)!);
      return true;
    });
    if (ok == true && mounted) {
      showToast(context, Strings.passwordChanged);
      Navigator.pop(context);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text('${Strings.resetPassword}: ${widget.user.fullName}'),
      content: SizedBox(
        width: 380,
        child: Form(
          key: _form,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextFormField(
                controller: _password,
                obscureText: true,
                autofocus: true,
                decoration: const InputDecoration(labelText: Strings.newPassword),
                validator: (v) => (v ?? '').length < AuthService.minPasswordLength ? Strings.passwordTooShort : null,
              ),
              TextFormField(
                controller: _confirm,
                obscureText: true,
                decoration: const InputDecoration(labelText: Strings.confirmPassword),
                validator: (v) => v != _password.text ? Strings.passwordsDontMatch : null,
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text(Strings.cancel)),
        FilledButton(onPressed: _save, child: const Text(Strings.save)),
      ],
    );
  }
}

final _usersProvider = StreamProvider.autoDispose<List<User>>((ref) => ref.watch(authServiceProvider).watchUsers());
