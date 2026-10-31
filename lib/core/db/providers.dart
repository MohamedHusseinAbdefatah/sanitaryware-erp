import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'database.dart';

/// Overridden in main.dart with the opened database.
final databaseProvider = Provider<AppDatabase>(
  (ref) => throw UnimplementedError('databaseProvider must be overridden'),
);
