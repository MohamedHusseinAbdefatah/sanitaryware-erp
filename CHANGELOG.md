# Changelog

Versions follow `version:` in `pubspec.yaml` and `lib/core/version.dart`.

## 1.1.0

For the supplier-price-list and orders upgrade. The database upgrades in
place (schema 10) and keeps all existing data.

- Stock is costed first-in, first-out: every purchase makes a cost layer,
  sales and returns use and restore the layers, and the cost on each sale
  line is the exact cost of the goods sold.
- Places: main warehouse, showroom and others, with transfers between them
  that keep the cost (Products, "Places and transfers").
- Reservations hold stock for a customer without moving it (Products).
- Supplier price lists (Excel import, new edition = new list) and optional
  supplier discounts by supplier, brand, category or product. A purchase
  invoice starts each line at the list price less the discount; it can be
  changed.
- Customer usual discount: filled into the discount of each sale line.
- Purchase orders: draft, approve (locks price and discount), receive in
  parts; each receipt is a normal purchase invoice.
- Sales orders and quotations: confirm (locks price and discount), deliver
  in parts; each delivery is a normal sales invoice. Channel and outside
  order id are kept. A cashier can give up to 5% extra discount; a sale
  below cost needs the admin and a reason. Exceptions are logged.

## 1.0.2

- Unexpected errors are written to `logs\errors.log` in the data folder
  (time, version, place, stack), including failed backups on close, which
  used to be silent.
- Only one copy of the program can run; starting it again brings the open
  window to the front. A restart after a restore waits for the old copy.
- Database schema 3: index for "paid on this invoice"; the monthly sales
  list with a year of data went from 0.7 s to 0.04 s.
- Release gate tests: upgrade from 1.0.0's folder and from older schemas,
  a busy year (15,000 invoices) with time limits, C++ files ASCII only.
- `docs/RELEASE_CHECKLIST.md`.

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
