import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sanitaryware_erp/app.dart';
import 'package:sanitaryware_erp/core/l10n/strings.dart';

void main() {
  testWidgets('app starts and shows the Arabic sidebar', (tester) async {
    await tester.pumpWidget(const ProviderScope(child: App()));
    await tester.pumpAndSettle();

    expect(find.text(Strings.appTitle), findsWidgets);
    expect(find.text(Strings.products), findsOneWidget);
  });
}
