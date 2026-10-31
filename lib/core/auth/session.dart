import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../db/database.dart';

/// The logged-in user, or null on the login screen.
final currentUserProvider = StateProvider<User?>((ref) => null);

/// True until the first-run setup has created the admin.
/// Overridden in main.dart with the real answer.
final setupNeededProvider = StateProvider<bool>((ref) => true);
