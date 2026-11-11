# Changelog

Versions follow `version:` in `pubspec.yaml` and `lib/core/version.dart`.

## 1.6.1

Fix for updated price lists. No database change.

- Fixed: a price list uploaded again with new prices (for example 10% up)
  under a different list type became a second list beside the old one, and
  purchases kept the old price because the supplier discount was on the old
  list. The import now shows the brand's list types to pick from, says when
  the upload is a new version, and warns in red when a new type would make a
  separate list.
- A new version of the same brand and list type now takes over the active
  buying and selling policies of the version it follows, with the same
  discounts. Before, a new version had no supplier discount until one was
  added again.
- A list sent again on the same day as the current version is accepted and
  replaces it from that day, instead of being refused. The old version stays
  on record.

## 1.6.0

The inventory is kept apart from the catalogue and the price lists. No
database change.

- New screen "المخزون" (Inventory): lists only products that came into stock
  (a purchase, opening stock, an adjustment or a return). Products loaded
  from a supplier's price list but never bought are not in it. Each row shows
  the balance, its places, how much is at the new and the old list price, the
  last receipt and, for the admin, the value at FIFO cost, with the total at
  the top. Filters: search, category, brand, under minimum, and "include sold
  out" for items bought and since sold out.
- "المنتجات والمخزون" becomes "الأصناف": the catalogue of every product,
  including those from price lists. Reservations, places and transfers and
  the under-minimum filter moved to the inventory screen.
- Dashboard links for items under minimum and stock with an unknown list now
  open the inventory.
- Guides updated with the new screen.

## 1.5.0

Price lists can be imported straight from a supplier's PDF. No database change.

- New on the Price Lists screen: "استيراد من PDF". Choose the brand, the file
  and the pages, then read it. The program reads the text in the file (codes,
  prices and the English description), finds the price columns from their
  headers (White, Pergamon, Colours, Price) or from where prices line up, and
  shows each column with its count and sample prices. The person ticks the
  columns to take and names each by its colour. The rows then go through the
  same preview, matching and review queue as an Excel file.
- Nothing is guessed: a number under no column, two prices under one column,
  a repeated code with different prices, or a new product with no name stops
  the row for review, shown with its page.
- Scanned PDFs (pictures with no text) are refused with a clear message; the
  pages that are pictures in a mixed file are listed so they can be entered by
  hand.
- The PDF is kept beside the database (price_list_sources\PL-n.pdf) and opens
  from the version's menu with "فتح ملف المصدر".
- Uses PDFium through the pdfrx package; pdfium.dll ships with the program.

## 1.4.0

A new look and a richer dashboard. No database change.

- New design: dark grouped sidebar (daily work, stock and buying, finance and
  admin) with the company name and the signed-in user, a top bar with the date
  and a "new sale" button, F9 for a new sale from any screen, framed lists with
  striped rows, clearer page headers, and a new login screen.
- Dashboard: quick actions, an attention strip (backup, low stock, cheques,
  price lists to review, stock with an unknown list), figure cards for today,
  this month against last month and what customers owe, and for the admin
  gross profit this month, stock value and what is owed to suppliers. Sales
  for the last 14 days, best sellers this month, items under minimum and top
  debtors.
- Arabic user guide updated, and a new English Application Guide,
  docs/application_guide_en.pdf, built from the program with every release.

## 1.3.0

The database upgrades in place (schema 12) and keeps all existing data.

- New: stock at the old and the new price. Each receipt remembers the price
  list version it came in under. The Products list, the sale screen, a dialog
  per product and a new report show how much is at the new price, at the old
  price, or not yet known. A person can say which list unknown stock belongs
  to, for one product or a whole list. Nothing is guessed.
- New report: stock by place, with what is display only.
- Fixed: sales always took stock from the main warehouse, so a place's stock
  went wrong after any transfer. A sale now takes from sellable places, main
  warehouse first, or from the place chosen on the line, and cancelling gives
  each place back its own.
- Fixed: display-only pieces could be sold. They no longer count as available.
- Fixed: purchase receipts, purchase returns, purchase cancels, sale returns,
  return cancels and stock adjustments now use the right place.
- Fixed: an invoice discount on a purchase now lowers the cost of the goods,
  split over the lines exactly. Costs already in stock are not rewritten.
- Fixed: the profit report uses each sale line's exact FIFO cost instead of a
  rounded average.
- Fixed: a credit limit override is written to the approval log.
- Fixed: edits to products, customers and suppliers record before and after.
- Price list import: a list with no codes matches by exact name within the
  brand, and more Excel files can be opened, such as those made by other tools.
- The stock card shows the place and names transfers and cancels properly.

## 1.2.0

Blueprint section 3, Product Master & Price Lists. Each requirement is traced
to its code and test in `docs/section3_product_master_price_lists.md`. The
database upgrades in place (schema 11) and keeps all existing data.

- The product is master data only: a fixed Product ID, the maker's code kept
  as text, a match key, and brand, category, subcategory, series, description,
  dimensions, variant, finish, unit, barcode, specs and verified VAT. It no
  longer holds any price, cost or balance.
- Cost comes only from FIFO layers. Weighted average cost is gone. Opening
  stock needs its quantity, location and actual cost.
- Every price list is a dated version with its own ID, brand, type, currency,
  period, import date, source, row count and VAT status. A new full version
  closes the earlier period; old rows are never changed.
- Two ways in: a full file, or a single product or small group with no file.
  Known codes get a price, new codes get a Product ID, and duplicate or
  ambiguous rows stop in a review queue.
- Buying policies (supplier + brand + list) and selling policies (brand + list
  + pricing type) are separate. Priority is product, then category, then all.
  With no buying policy no discount is assumed.
- Every document line keeps the version it used and each discount. An approved
  order keeps its version when a later one starts.
- An invoice discount is split over its lines exactly, for profit and tax.
- Before approval a sale shows the list price, each discount and its source,
  the final price, VAT, FIFO cost, gross profit, margin, markup and any
  approval needed.
- A cashier cannot post a price that is not the approved list price, a discount
  past the limit, or a margin under the minimum; an admin can, and it is logged.

After upgrading: prices that were on products, old supplier lists and old
supplier discounts are kept but wait for review on the Price Lists screen.
Until then those products have no approved price.

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
