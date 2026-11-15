import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/auth/session.dart';
import '../../core/db/database.dart';
import '../../core/l10n/strings.dart';
import '../../core/providers.dart';
import '../../core/theme.dart';
import '../../core/widgets/feedback.dart';

final _contactsProvider = StreamProvider.autoDispose.family<List<CustomerContact>, int>(
    (ref, customerId) => ref.watch(partyServiceProvider).watchContacts(customerId));

/// The people to deal with at a customer: the engineer, the site manager,
/// the accountant who pays.
class ContactsTab extends ConsumerWidget {
  const ContactsTab({super.key, required this.customerId});

  final int customerId;

  Future<void> _edit(BuildContext context, WidgetRef ref, [CustomerContact? c]) async {
    final saved = await showDialog<bool>(context: context, builder: (_) => _ContactDialog(customerId: customerId, contact: c));
    if (saved == true && context.mounted) showToast(context, 'تم حفظ جهة الاتصال');
  }

  Future<void> _delete(BuildContext context, WidgetRef ref, CustomerContact c) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        content: Text('حذف ${c.name} من جهات الاتصال؟'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text(Strings.cancel)),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('حذف')),
        ],
      ),
    );
    if (ok != true || !context.mounted) return;
    await runGuarded(
        context, () => ref.read(partyServiceProvider).deleteContact(c.id, userId: ref.read(currentUserProvider)?.id));
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final list = ref.watch(_contactsProvider(customerId)).valueOrNull ?? const <CustomerContact>[];
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Align(
          alignment: AlignmentDirectional.centerStart,
          child: FilledButton.tonalIcon(
            onPressed: () => _edit(context, ref),
            icon: const Icon(Icons.person_add_alt_1_outlined),
            label: const Text('إضافة جهة اتصال'),
          ),
        ),
        const SizedBox(height: 8),
        if (list.isEmpty)
          const Padding(
            padding: EdgeInsets.all(24),
            child: Text('لا توجد جهات اتصال. أضف المهندس أو مدير الموقع أو المحاسب المسؤول عن الدفع.',
                textAlign: TextAlign.center, style: TextStyle(color: AppColors.muted)),
          ),
        for (final c in list)
          Card(
            child: ListTile(
              leading: const CircleAvatar(child: Icon(Icons.person_outline)),
              title: Text(c.role == null ? c.name : '${c.name} — ${c.role}'),
              subtitle: Text([c.phone, c.email].whereType<String>().join('  ·  ')),
              trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                IconButton(tooltip: Strings.edit, icon: const Icon(Icons.edit_outlined), onPressed: () => _edit(context, ref, c)),
                IconButton(tooltip: 'حذف', icon: const Icon(Icons.delete_outline), onPressed: () => _delete(context, ref, c)),
              ]),
            ),
          ),
      ],
    );
  }
}

class _ContactDialog extends ConsumerStatefulWidget {
  const _ContactDialog({required this.customerId, this.contact});

  final int customerId;
  final CustomerContact? contact;

  @override
  ConsumerState<_ContactDialog> createState() => _ContactDialogState();
}

class _ContactDialogState extends ConsumerState<_ContactDialog> {
  final _form = GlobalKey<FormState>();
  late final _name = TextEditingController(text: widget.contact?.name);
  late final _role = TextEditingController(text: widget.contact?.role);
  late final _phone = TextEditingController(text: widget.contact?.phone);
  late final _email = TextEditingController(text: widget.contact?.email);

  @override
  void dispose() {
    for (final c in [_name, _role, _phone, _email]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _save() async {
    if (!_form.currentState!.validate()) return;
    final id = await runGuarded(
      context,
      () => ref.read(partyServiceProvider).saveContact(
            id: widget.contact?.id,
            customerId: widget.customerId,
            name: _name.text,
            role: _role.text,
            phone: _phone.text,
            email: _email.text,
            userId: ref.read(currentUserProvider)?.id,
          ),
    );
    if (id != null && mounted) Navigator.pop(context, true);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.contact == null ? 'جهة اتصال جديدة' : 'تعديل جهة الاتصال'),
      content: SizedBox(
        width: 420,
        child: Form(
          key: _form,
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            TextFormField(
              controller: _name,
              autofocus: true,
              decoration: const InputDecoration(labelText: Strings.name),
              validator: (v) => (v ?? '').trim().isEmpty ? Strings.required : null,
            ),
            TextFormField(
              controller: _role,
              decoration: const InputDecoration(labelText: 'الصفة (مهندس، مدير موقع، محاسب...)'),
            ),
            TextFormField(controller: _phone, decoration: const InputDecoration(labelText: Strings.phone)),
            TextFormField(
              controller: _email,
              decoration: const InputDecoration(labelText: 'البريد الإلكتروني'),
              validator: (v) {
                final t = (v ?? '').trim();
                return t.isEmpty || RegExp(r'^[^\s@]+@[^\s@]+\.[^\s@]+$').hasMatch(t) ? null : 'بريد غير صحيح';
              },
            ),
          ]),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text(Strings.cancel)),
        FilledButton(onPressed: _save, child: const Text(Strings.save)),
      ],
    );
  }
}
