# Changelog

Versions follow `version:` in `pubspec.yaml` and `lib/core/version.dart`.

## 1.0.1

- The data folder is now fixed at `%APPDATA%\SanitarywareERP`. Earlier
  builds let Windows name it after the program's company and product names,
  so 1.0.0 (renamed for the installer) started an empty database in a new
  folder. On first start the most recently used older folder is copied in;
  the old folder is left untouched.
- The logo is found next to the data if its saved path has moved.
- `reset_password.bat` for the developer when nobody can log in.

## 1.0.0 — first delivery

Everything in the signed v1 scope:

- Arabic right-to-left interface, Cairo font, first-run setup, login with
  admin and cashier roles, users screen, audit log.
- Products with categories, brands and units (meters sell in fractions),
  opening stock, stock adjustments, stock card, low-stock highlight.
- Customers and suppliers with opening balances, price levels (retail,
  wholesale, contractor), credit limits, statements with running balance.
- Sales invoices (cash, credit, partial payment), purchase invoices with
  weighted average cost, cancellation with reason (admin), sale and
  purchase returns.
- Payments in and out, linked to an invoice or on account; cheques with
  due dates, cleared and bounced.
- Expenses by category.
- Dashboard and eleven reports with date filters, Excel export and print.
- A4 printing: sales and purchase invoices, receipts, statements, reports,
  with the shop logo.
- Excel import of products, customers and suppliers with a preview.
- Backup on close, manual backup, external folder copy, keep last 10,
  restore, backup before any database upgrade, integrity check at start,
  warning when the external copy is older than 7 days.
