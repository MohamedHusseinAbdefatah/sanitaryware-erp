# Changelog

Versions follow `version:` in `pubspec.yaml` and `lib/core/version.dart`.

## 2.0.0

Accounting, projects, financial statements and charts. Database schema 17;
the upgrade builds the books from every existing document on first start.

- Double-entry books built from the documents themselves: every sales and
  purchase invoice, payment, cheque, return, expense, stock adjustment,
  opening stock and opening balance posts its own entry automatically, and
  changes or voids with it. Nothing is typed twice. Cost of sales is the
  exact FIFO cost; VAT is split out only where it is verified.
- A starting chart of accounts suited to a sanitaryware showroom (cash, bank,
  cheques under collection, customers, stock, supplier advances, VAT, fixed
  assets, loans, capital, sales, returns, cost of sales, operating expenses).
  Each expense category gets its own account. New accounts can be added.
- Manual entries for what has no document: opening cash and bank, capital,
  owner's drawings, fixed assets, depreciation, bank charges, corrections.
  They must balance; quick templates fill the usual ones. Customers,
  suppliers, stock, cheques and advances move only from their documents, so
  the books always equal the statements and the stock value.
- Account ledger with running balance for any account, linked to the source
  documents. Journal with filters and search.
- Statements: trial balance, profit and loss with comparison to the previous
  period and margins, balance sheet with ratios, cash flow (operating,
  investing, financing), VAT report, and aging of customers and suppliers
  (not due, 1-30, 31-60, 61-90, over 90 days). All export to Excel.
- Accounting overview: cash, bank, cheques, receivables (with overdue),
  payables, stock value, month's profit, a 12-month sales/costs/profit chart,
  the month's expenses, top debtors and creditors, and an aging bar.
- Period closing: close the books up to a day so nothing dated in it can be
  added or cancelled; reopen with a reason (recorded in the audit log).
  Enforced in the database itself. A rebuild of the books from the documents
  is available as a check.
- Projects: sites and contractors with their customer, location, site
  contact, dates, contract value and payment terms. A bill of quantities per
  project showing for each line what was quoted, ordered, bought, delivered,
  what is left, what is in stock and what still has to be bought. One click
  makes a quotation for what is left (priced by the usual lists and
  discounts) or purchase orders for the shortages per preferred supplier.
- Project profitability: revenue without VAT after returns, exact cost of
  what was delivered, project expenses, net profit and margin, collected and
  still due, and orders not yet invoiced. Invoices delivered from a project's
  order belong to the project automatically; a sale or expense can be
  entered for a project; earlier documents of the customer can be linked.
- The sidebar gains Projects and Accounting (admin only).

## 1.11.0

A new look for the screens, in the manner of a full ERP. No database change
and no new features beyond the screens.

- Record pages: clicking a supplier, customer or product opens its page
  instead of the edit form. A header with its actions (a new invoice already
  for that party, a payment, the statement, an advance, editing), key
  figures, and tabs: invoices with their state, payments with cheque state,
  orders, advances, returns, reservations, products bought or sold most,
  agreed discounts and details. A product page shows its photo, stock by
  place, available after reservations, new and old price, list prices in
  force, movements, purchases (admin), sales, reservations and price history.
- Lists of sales, purchases, payments, cheques, returns and expenses show the
  period's figures on top, filter chips with counts (paid, partly paid,
  unpaid, overdue, cancelled) and coloured states; party names link to their
  pages.
- A posted sales or purchase invoice opens as a document: a status bar
  (issued, partly paid, paid, or cancelled), the party as a link, the lines
  with links to the products, the totals and the payments made on it.
- Sales orders and purchase orders have screens of their own with the open
  orders, the value still to deliver or receive, and filters by stage.
- New sale and purchase screens can open with the customer or supplier
  already chosen.

## 1.10.0

Product photos and Arabic names from price lists. The database upgrades in
place (schema 16, one new table) and keeps all existing data.

- A photo per product: open the product to edit it, then "اختيار صورة" (JPG,
  PNG, WebP, BMP or GIF). It is shrunk to a JPEG of at most 800 px and kept
  inside the database, so backups and restores carry it. A small thumbnail
  shows in the Products and Inventory lists; clicking it shows the photo.
- Price list import reads an Arabic name column ("الاسم بالعربي", "الاسم
  العربي" or "Arabic name") beside the list's own name. New products are
  named in Arabic and keep the English name as their description. Known
  products named only in English get the Arabic name (shown as a count
  before saving, written to the audit log); an Arabic name already there is
  never replaced. A list whose only name column is Arabic does the same.
- The price list format guide lists the new column.

## 1.9.0

Reservations come from orders, and money paid to a supplier ahead is locked
to that day's price lists. The database upgrades in place (schema 15) and
keeps all existing data; existing reservations stay as they were.

- Reservations are no longer typed by hand. Confirming a customer's sales
  order holds what is in stock for him. The order shows, line by line, what
  is held, what is on order from a supplier, and what is short.
  "اطلب الناقص من مورد" puts the shortage on a draft purchase order tied to
  that order; when it is received (from the purchase order or "from a
  purchase order" on the purchase invoice) the goods are held for that
  customer. "احجز ما وصل للمخزن" holds goods that came in another way.
  Delivering a line in full or cancelling the order releases its holds. The
  admin can still release a reservation from the reservations screen.
- New: supplier advance locked to a price list (supplier menu, "دفعات مقدمة
  بسعر قائمة"). An amount paid ahead (cash, bank or cheque) locks the price
  lists in force that day for the brands chosen, and the supplier's discount
  on them that day. It counts in the supplier's balance at once.
- A purchase invoice for that supplier can be taken "from the advance": every
  line is priced from the locked list and discount, whatever newer lists
  exist, and the invoice is paid from the advance, which shows what was taken
  and what is left. An invoice bigger than what is left, or a product not on
  the locked lists, is refused. Cancelling the invoice gives its value back;
  an advance can be cancelled only while nothing was taken.

## 1.8.0

A fuller purchase invoice. The database upgrades in place (schema 14, new
columns only) and keeps all existing data.

- Each line shows the list price, the supplier's agreed discount, an extra
  discount % for that line, and the final cost. The list version is kept on
  the line even when the cost is typed, so stock knows its list.
- A cost above the list price less the agreed discount is marked orange on
  the line, with both discounts, and asked about before saving.
- Transport and unloading: added to the goods' cost, split over the lines by
  value after the invoice discount. "On the supplier's invoice" adds it to
  what the supplier is owed; "paid to someone else" records a purchase
  expense (category "نقل وتحميل مشتريات") tied to the invoice. Net profit does
  not take that expense off again, since it is in the cost of the goods.
- The supplier's invoice number already used for the same supplier is asked
  about before saving.
- Paid now can be a cheque (number, bank, due date). What is left can have a
  due date; the dashboard lists supplier invoices due within a week and an
  attention line for overdue ones.
- "From a purchase order": fills the order's remaining lines at their locked
  cost; quantities can be lowered (partial receipt) and other products added
  to the same invoice. "From a price list": tick products of a list, with a
  search and quantities, and add them at once.
- The saved invoice shows each line's list price, discount and cost in stock,
  the transport, and the due date. Cancelling it also cancels its pending
  cheque and its transport expense.

## 1.7.0

Customer categories and a simpler way to give selling discounts. The
database upgrades in place (schema 13) and keeps all existing data.

- New: customer categories. The shop starts with قطاعي، جملة، مشروعات
  ومقاولون and مهندسين, and can add its own. Each has a usual discount on the
  list price (0% until the owner sets it). Every customer has a category,
  chosen on the customer card; a sale with no customer is retail. The
  customer's own discount now reads "extra discount for this customer" and
  adds on top.
- Selling policies become "خصومات البيع" (Price Lists screen): the categories
  with their usual discount, and optional special discounts by category +
  brand (or every brand) + all, a product category or a product, with an
  optional maximum discount and minimum margin. A special discount replaces
  the usual one. They are no longer tied to a price list version, so a new
  list needs nothing re-entered.
- Upgrading: each old price level becomes its category (retail, wholesale,
  projects and contractors), and each old selling policy becomes a special
  discount for that category and brand with the same discount and limits.
- The invoice discount on sales and purchases can be typed as an amount or as
  a percent of the subtotal (a switch beside it). The invoice keeps the amount.
- Customer import reads the category by its name (column "فئة العميل").
- New for the shop staff: docs/price_list_format_ar.pdf, how to prepare a
  price list file, with two Excel templates in docs/templates (one price per
  row, or one price column per colour), both checked with the real importer.

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
