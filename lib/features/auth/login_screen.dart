import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/auth/auth_service.dart';
import '../../core/auth/session.dart';
import '../../core/l10n/strings.dart';
import '../../core/providers.dart';
import '../../core/theme.dart';
import '../../core/version.dart';

class LoginScreen extends ConsumerStatefulWidget {
  const LoginScreen({super.key});

  @override
  ConsumerState<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends ConsumerState<LoginScreen> {
  final _username = TextEditingController();
  final _password = TextEditingController();
  final _passwordFocus = FocusNode();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _username.dispose();
    _password.dispose();
    _passwordFocus.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final user = await ref.read(authServiceProvider).login(_username.text, _password.text);
      ref.read(currentUserProvider.notifier).state = user;
    } on AuthException catch (e) {
      _password.clear();
      _passwordFocus.requestFocus();
      setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      body: Row(
        children: [
          Expanded(
            child: Container(
              color: AppColors.brandDark,
              padding: const EdgeInsets.all(48),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    width: 64,
                    height: 64,
                    decoration: BoxDecoration(color: AppColors.brand, borderRadius: BorderRadius.circular(16)),
                    child: const Icon(Icons.water_drop, color: Colors.white, size: 36),
                  ),
                  const SizedBox(height: 24),
                  const Text(
                    'نظام متكامل لإدارة المحل',
                    style: TextStyle(color: Colors.white, fontSize: 28, fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: 12),
                  for (final line in const [
                    'المبيعات والعروض والأوامر',
                    'المخزون بالأماكن وتكلفة FIFO',
                    'قوائم الأسعار وسياسات الخصم',
                    'المشتريات والموردون والمدفوعات',
                    'التقارير والنسخ الاحتياطي',
                  ])
                    Padding(
                      padding: const EdgeInsets.only(bottom: 6),
                      child: Row(
                        children: [
                          const Icon(Icons.check_circle, color: AppColors.sideAccent, size: 18),
                          const SizedBox(width: 8),
                          Text(line, style: const TextStyle(color: AppColors.sideText, fontSize: 15)),
                        ],
                      ),
                    ),
                ],
              ),
            ),
          ),
          Expanded(
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 380),
                child: Card(
                  child: Padding(
                    padding: const EdgeInsets.all(28),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Text(Strings.appTitle, style: theme.textTheme.headlineSmall, textAlign: TextAlign.center),
                        const SizedBox(height: 4),
                        Text(Strings.loginTitle, style: theme.textTheme.titleMedium, textAlign: TextAlign.center),
                        Text(
                          '${Strings.version} $appVersion',
                          style: theme.textTheme.bodySmall,
                          textAlign: TextAlign.center,
                        ),
                        const SizedBox(height: 24),
                        TextField(
                          controller: _username,
                          autofocus: true,
                          decoration: const InputDecoration(
                            labelText: Strings.username,
                            prefixIcon: Icon(Icons.person_outline),
                          ),
                          onSubmitted: (_) => _passwordFocus.requestFocus(),
                        ),
                        const SizedBox(height: 12),
                        TextField(
                          controller: _password,
                          focusNode: _passwordFocus,
                          obscureText: true,
                          decoration: const InputDecoration(
                            labelText: Strings.password,
                            prefixIcon: Icon(Icons.lock_outline),
                          ),
                          onSubmitted: (_) => _submit(),
                        ),
                        if (_error != null) ...[
                          const SizedBox(height: 16),
                          Text(_error!, style: TextStyle(color: theme.colorScheme.error)),
                        ],
                        const SizedBox(height: 24),
                        FilledButton(
                          onPressed: _busy ? null : _submit,
                          child: _busy
                              ? const SizedBox.square(dimension: 20, child: CircularProgressIndicator(strokeWidth: 2))
                              : const Text(Strings.login),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
