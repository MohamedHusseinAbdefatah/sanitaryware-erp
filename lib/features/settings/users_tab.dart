import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/auth/auth_service.dart';
import '../../core/auth/remember_service.dart';
import '../../core/dates.dart';
import '../../core/theme.dart';
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
        if (me?.isAdmin ?? false) const _RememberedLogins(),
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
                DataListColumn(Strings.role, numeric: true, (u) => Text(UserRole.label(u.role))),
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
              DropdownButtonFormField<String>(
                initialValue: UserRole.all.contains(_role) ? _role : UserRole.cashier,
                decoration: const InputDecoration(labelText: Strings.role),
                items: [
                  for (final r in UserRole.all) DropdownMenuItem(value: r, child: Text(UserRole.label(r))),
                ],
                onChanged: (v) => setState(() => _role = v ?? _role),
              ),
              const SizedBox(height: 4),
              Text(UserRole.describe(_role), style: Theme.of(context).textTheme.bodySmall),
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

final _rememberedProvider = StreamProvider.autoDispose<List<RememberedRow>>(
    (ref) => ref.watch(rememberServiceProvider).watchActive());

/// Owner: whether "remember me" is allowed, and the sign-ins remembered now,
/// each of which can be ended ("log out everywhere" for that user).
class _RememberedLogins extends ConsumerWidget {
  const _RememberedLogins();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final enabled = ref.watch(rememberEnabledProvider).valueOrNull ?? false;
    final rows = ref.watch(_rememberedProvider).valueOrNull ?? const <RememberedRow>[];
    final me = ref.watch(currentUserProvider)!;
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 0, 24, 12),
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Row(children: [
              const Icon(Icons.verified_user_outlined, color: AppColors.brand),
              const SizedBox(width: 8),
              const Expanded(
                child: Text('تذكر الدخول على الجهاز', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 15)),
              ),
              Switch(
                value: enabled,
                onChanged: (v) async {
                  await runGuarded(context, () async {
                    await ref.read(rememberServiceProvider).setEnabled(v, by: me);
                    return true;
                  });
                  ref.invalidate(rememberEnabledProvider);
                },
              ),
            ]),
            Text(
              enabled
                  ? 'يمكن لكل مستخدم اختيار «تذكرني» عند الدخول؛ يُحفظ رمز عشوائي على الجهاز (وليس كلمة المرور) لمدة 30 يوماً. '
                      'إيقاف الخيار ينهي كل الدخول المحفوظ فوراً.'
                  : 'موقوف: كل مستخدم يكتب كلمة المرور في كل مرة.',
              style: const TextStyle(color: AppColors.muted, fontSize: 12.5),
            ),
            if (rows.isNotEmpty) ...[
              const Divider(),
              for (final r in rows)
                ListTile(
                  dense: true,
                  leading: const Icon(Icons.computer_outlined),
                  title: Text('${r.userName} — ${r.login.deviceName ?? 'جهاز'}'),
                  subtitle: Text('منذ ${formatDateTime(r.login.createdAt)} · ينتهي ${formatDate(r.login.expiresAt)}'),
                  trailing: TextButton.icon(
                    onPressed: () async {
                      final n = await runGuarded(
                          context, () => ref.read(rememberServiceProvider).revokeAllFor(r.login.userId, by: me));
                      if (n != null && context.mounted) showToast(context, 'تم إنهاء الدخول المحفوظ لـ ${r.userName}');
                    },
                    icon: const Icon(Icons.logout, size: 18),
                    label: const Text('خروج من كل الأجهزة'),
                  ),
                ),
            ],
          ]),
        ),
      ),
    );
  }
}
