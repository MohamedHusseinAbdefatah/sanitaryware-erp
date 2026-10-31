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

The database lives in the user's app-data folder (`SanitarywareERP\erp.sqlite`),
not next to the program files.
