import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sanitaryware_erp/app.dart';
import 'package:sanitaryware_erp/core/db/database.dart';
import 'package:sanitaryware_erp/core/db/providers.dart';
import 'package:sanitaryware_erp/core/l10n/strings.dart';

void main() {
  testWidgets('app starts and shows the Arabic sidebar', (tester) async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [databaseProvider.overrideWithValue(db)],
        child: const App(),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text(Strings.appTitle), findsWidgets);
    expect(find.text(Strings.products), findsOneWidget);
  });
}
