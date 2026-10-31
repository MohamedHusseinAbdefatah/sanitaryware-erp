import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/auth/auth_service.dart';
import '../../core/auth/session.dart';
import '../../core/l10n/strings.dart';
import '../../core/providers.dart';
import '../../core/services/settings_service.dart';

/// Shown once, on the very first start: company data and the admin account.
class SetupScreen extends ConsumerStatefulWidget {
  const SetupScreen({super.key});

  @override
  ConsumerState<SetupScreen> createState() => _SetupScreenState();
}

class _SetupScreenState extends ConsumerState<SetupScreen> {
  final _form = GlobalKey<FormState>();
  final _companyName = TextEditingController();
  final _companyAddress = TextEditingController();
  final _companyPhone = TextEditingController();
  final _fullName = TextEditingController();
  final _username = TextEditingController();
  final _password = TextEditingController();
  final _confirm = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    for (final c in [
      _companyName,
      _companyAddress,
      _companyPhone,
      _fullName,
      _username,
      _password,
      _confirm,
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _submit() async {
    if (_busy || !_form.currentState!.validate()) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final admin = await ref.read(authServiceProvider).firstRunSetup(
            company: CompanyInfo(
              name: _companyName.text,
              address: _companyAddress.text,
              phone: _companyPhone.text,
            ),
            fullName: _fullName.text,
            username: _username.text,
            password: _password.text,
          );
      ref.read(currentUserProvider.notifier).state = admin;
      ref.read(setupNeededProvider.notifier).state = false;
    } on AuthException catch (e) {
      setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  String? _requiredField(String? v) =>
      (v == null || v.trim().isEmpty) ? Strings.required : null;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 560),
            child: Card(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Form(
                  key: _form,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(Strings.setupTitle, style: theme.textTheme.headlineSmall),
                      const SizedBox(height: 8),
                      const Text(Strings.setupIntro),
                      const SizedBox(height: 24),
                      Text(Strings.companySection, style: theme.textTheme.titleMedium),
                      const SizedBox(height: 8),
                      TextFormField(
                        controller: _companyName,
                        decoration: const InputDecoration(labelText: Strings.companyName),
                        validator: _requiredField,
                        autofocus: true,
                      ),
                      TextFormField(
                        controller: _companyAddress,
                        decoration: const InputDecoration(labelText: Strings.companyAddress),
                      ),
                      TextFormField(
                        controller: _companyPhone,
                        decoration: const InputDecoration(labelText: Strings.companyPhone),
                      ),
                      const SizedBox(height: 24),
                      Text(Strings.adminSection, style: theme.textTheme.titleMedium),
                      const SizedBox(height: 8),
                      TextFormField(
                        controller: _fullName,
                        decoration: const InputDecoration(labelText: Strings.fullName),
                        validator: _requiredField,
                      ),
                      TextFormField(
                        controller: _username,
                        decoration: const InputDecoration(labelText: Strings.username),
                        validator: _requiredField,
                      ),
                      TextFormField(
                        controller: _password,
                        obscureText: true,
                        decoration: const InputDecoration(labelText: Strings.password),
                        validator: (v) => (v ?? '').length < AuthService.minPasswordLength
                            ? 'كلمة المرور يجب ألا تقل عن ${AuthService.minPasswordLength} أحرف'
                            : null,
                      ),
                      TextFormField(
                        controller: _confirm,
                        obscureText: true,
                        decoration: const InputDecoration(labelText: Strings.confirmPassword),
                        validator: (v) =>
                            v != _password.text ? Strings.passwordsDontMatch : null,
                        onFieldSubmitted: (_) => _submit(),
                      ),
                      if (_error != null) ...[
                        const SizedBox(height: 16),
                        Text(_error!, style: TextStyle(color: theme.colorScheme.error)),
                      ],
                      const SizedBox(height: 24),
                      FilledButton(
                        onPressed: _busy ? null : _submit,
                        child: _busy
                            ? const SizedBox.square(
                                dimension: 20,
                                child: CircularProgressIndicator(strokeWidth: 2),
                              )
                            : const Text(Strings.finishSetup),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
