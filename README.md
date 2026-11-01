# Sanitaryware ERP

Offline Windows desktop app (Arabic, right-to-left) for a sanitaryware supply
business: products and stock, customers and suppliers, sales and purchase
invoices, payments and cheques, returns, expenses, reports, backup.

Built with Flutter, Riverpod, go_router and drift (SQLite).

## Rules that keep the numbers right

- Money is stored as integer piastres (`lib/core/money.dart`), never `double`.
- Stock is never edited directly: current stock is the sum of `stock_movements`.
- Financial records are never deleted; they are cancelled with a `status`.
- Every change that touches money or stock runs inside one drift transaction.

## Development

```bat
check.bat
```

Regenerates the drift code, runs `flutter analyze` and `flutter test`, and
writes the output to `check_log.txt`.

Run the app with `flutter run -d windows`.

The database lives in `%APPDATA%\SanitarywareERP\erp.sqlite` (fixed on
purpose, see `lib/core/db/data_dir.dart`), not next to the program files.

## Release and delivery

- `build_release.bat` runs every test, builds the release and makes
  `dist\SanitarywareERP-Setup-<version>.exe` (needs Inno Setup 6).
- The version lives in `lib/core/version.dart`, `pubspec.yaml` and
  `CHANGELOG.md` (a test keeps them in step).
- `test/acceptance/manual_script_test.dart` is the plan's manual test
  script with hand-calculated totals: the release gate.

## Documents for the client (`docs/`)

- `user_guide_ar.pdf`: the Arabic user guide. Rebuild it after UI changes:

  ```bat
  flutter test tool/docs/screenshots_test.dart
  flutter test tool/docs/user_guide_test.dart
  ```

- `recovery_sheet_ar.md`: the "if something goes wrong" page.
- `reset_password.bat`: for the developer when nobody can log in (for
  example the only admin forgot the password). Close the program first; it
  backs up the database, sets the new password and re-activates the user.
- `handover_checklist_ar.md`: the checklist signed at delivery.
