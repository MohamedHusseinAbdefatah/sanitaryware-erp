# Changelog

Versions follow `version:` in `pubspec.yaml` and `lib/core/version.dart`.

## 2.6.1

No database change.

- Purchase invoice for a supplier with an advance: a banner at the top shows
  the advance left and a clear choice, "فاتورة عادية" or "خصم من الدفعة
  المقدمة". Taking from the advance fills the amount to the invoice total
  (up to what is left) and follows it as lines are added; the rest stays on
  the supplier's account or is paid now. The amount can still be typed in
  "من الدفعات المقدمة", and a saved invoice can still take from the advance
  later from its own page.

## 2.6.0

The client's requests after 2.5.1: correcting mistakes without friction.
No database change.

- Price lists: "حذف القائمة" deletes a list entered by mistake for good
  (with its rows and the discounts set on it) when no document used it; a
  list documents used is withdrawn instead and kept for them. Either way the
  products only that list brought in, never used, are deleted with it, and
  the version of the same type before it is in force again (withdrawing the
  newest list used to leave its products with no price).
- Products: "حذف الصنف" on each product and "حذف المحدد" in selection mode.
  A product nothing used (no stock, document, order, reservation or project
  line) is deleted for good with its photo; its price-list rows are unlinked.
  Used ones are listed with what uses them and offered to be switched off.
- Customers and suppliers: "حذف" for one entered by mistake with no
  dealings at all; its opening balance leaves the books with it. One with
  dealings is refused with what it is used in.
- Payments: "حذف الدفعة" works on every payment, a supplier advance
  included (with its advance; refused while invoices use it). "تعديل
  الدفعة" also changes the supplier or customer (a payment to the wrong
  supplier; it leaves the invoice it paid and stays on the new party's
  account) and cash / bank. Both are also on each supplier's and
  customer's page. Deleted payments leave the lists; "عرض المحذوفة" shows them.
- Reasons are optional for deleting, cancelling, withdrawing and correcting.
  They stay required only for reopening a closed period, a bounced cheque,
  rejected goods and a stock adjustment.
- Model number: a tag beside the product's name in the products and
  inventory lists, the product search, the product browser, invoice and
  order lines, the product page header, and on printed sales and purchase
  invoices.
- Purchase invoice: each line shows where it is received and can be sent to
  another place; "تقسيم على مكان آخر" splits a line (part to the showroom,
  part to the warehouse). Cancelling takes each part back from its place.

## 2.5.1

The client's requests of 21 November. No database change.

- Purchase orders print as "طلب توريد" in two copies: one for the supplier
  (or customer) with code, product and quantity and no prices, and an
  internal copy with list price, discount, net cost, line totals and the
  order total. Both from the purchase order window.
- Sales invoice: the discount on a line is a percent of the line (20 = 20%
  off the list price), with the amount it takes off shown under it. Empty is
  no discount. The customer's or policy discount fills in as a percent (21%
  and one point = 22). The invoice still keeps the discount as an amount,
  so nothing changes in saved invoices, the books or the reports.
- Printer test page: the signature and print date follow the content
  instead of the very foot of the sheet, and the page keeps the printer's own
  margins, as every document already did. They no longer print half cut.
- Price lists: a new version made from "إدخال صنف أو مجموعة أصناف" can be
  given its VAT basis and rate, as the full import already could.
- Fix: a manufacturer code typed with an Arabic vowel mark (a kasra from an
  Arabic keyboard), a tatweel or an invisible character copied from a PDF
  or a chat passed the duplicate check as a different code. These are now
  ignored when codes are compared; the code is still saved as typed. Codes
  saved by earlier versions are re-compared on the first start.

## 2.5.0

Look, navigation and ease of use. No database change, no change to any
calculation, permission or workflow; every page, button and field is still
there.

Design system
- One set of colours, spacing, corner, shadow and type tokens
  (`lib/core/theme.dart`) used by every screen; component themes for
  buttons, fields, menus, dialogs, tabs, chips, checkboxes, date picker,
  tooltips and toasts. A visible focus ring for keyboard users.
- Status labels carry a dot or icon, so a state is never told by colour
  alone.

Navigation
- Sidebar: groups can be folded; the open page is lit with an edge bar; the
  whole sidebar folds to icons (button or Ctrl+B, remembered); medium
  windows show icons only and narrow windows a menu button.
- Top bar: back button and breadcrumb, quick search, a "إنشاء" menu for
  new documents (by role), keyboard help (F1), new sale (F9).
- Quick search (Ctrl+K): pages, products (code, model, barcode), customers,
  suppliers, sale and purchase invoice numbers (also the supplier's own
  number) and projects. Shows only what the user's role may open.

Lists and feedback
- Tables: click a heading to sort (again to reverse), row count under each
  table, hover highlight, clearer empty states.
- Page headers with an icon and a line saying what the page is for.
- Toasts with an icon and colour for success, information, warning and
  error. Deleting a project task, a BOQ line, a price-list category or a
  product photo now asks first.
- Dashboard: "يحتاج انتباهك" panel, clearer figure cards, loading and error
  states with a retry.
- Price lists: each version shows its state as an icon label and a coloured
  edge (سارية، تبدأ لاحقاً، تاريخية، موقوفة، مسحوبة، قيد المراجعة).
- Invoice entry: the total stands out; the amount remaining is coloured.

See docs/ui_upgrade.md for the audit, what changed and what is suggested
next.

## 2.4.0

Database schema 20 (new columns and tables only; nothing removed). On the
first start the database is backed up, then upgraded.

Price lists
- Lists from the past: a 2024 list can be uploaded today. It takes its own
  place in time and ends the day before the next list of the same type; the
  newer lists and their prices are never touched. Dates back to 2000. Each
  list shows when it was in force and when it was entered in the program.
- Switch a list off and on (owner): a switched-off list prices no new
  invoice or order and stays readable for every document that used it.
  "Withdraw" is still there for a list entered by mistake.
- Filters by brand, list type, category and year; states "سارية",
  "تاريخية", "موقوفة", "مسحوبة".
- Model number: its own field on products and list rows, read from columns
  such as "Model No.", "الموديل", "رقم الموديل" (any case or punctuation, also
  under a title row), shown and searchable everywhere. A list fills it on a
  known product that has none and never overwrites one. With no code column
  the model number stands as the code, as before. CSV files are read too.
- Categories of lists (فاخر، متوسط، اقتصادي...), made by the owner, each with
  its buying discount. With no discount recorded for the supplier, the
  list's category discount prices the purchase; the invoice line keeps the
  category and discount it used, so changing a category's discount never
  changes a saved invoice.

Selling
- Discount by brand and customer type: a grid in "خصومات البيع" (for example
  Duravit 10%, Ideal Standard 5% for retail). A brand without its own
  discount takes the customer type's usual one. Saved sales keep their
  discount.

Suppliers and purchases
- Supplier advances belong to the supplier, not to a price list. Any
  purchase invoice of that supplier (any brand or list) can take part of the
  advance balance, when it is entered or later from the invoice. Each use is
  an allocation row linking one advance to one invoice; more than is left,
  or more than the invoice owes, is refused. Advances locked to lists before
  2.4 become supplier balance with their amounts unchanged.
- Purchase invoice discount: none, an amount or a percent; the percent is
  kept with the invoice and shown on it.

Owner corrections (each in the audit log with the value before, after and
the reason)
- A supplier or customer payment: amount, date, notes. Balances, the invoice
  it pays and the books follow.
- A saved purchase invoice: the corrected one replaces it, its payments and
  advance amount move over, and the old one stays on record as cancelled.
- Purchase policies and selling discounts; a use of a supplier advance.

Stock
- Stock entered by hand (owner), for stock bought before the program: the
  original purchase date, a historical price list, list price, discount (%
  or amount per unit) and the resulting cost. No supplier invoice, no
  payment; the value goes to the opening balance in the books. Duplicates
  are caught; an entry can be cancelled while its stock is untouched.

Projects
- A plan for each project: tasks, milestones and deliveries with who is
  responsible, start and due days, state (لم يبدأ، جاري التنفيذ، مكتمل، متأخر)
  and progress. Moving a task keeps the day first planned, so planned and
  real days are compared. Completion, late and delayed milestones at a glance,
  and a timeline.
- Weekly and monthly calendar of all projects; drag a task to another day.
- Reminders: the dashboard shows late tasks and those due soon.

Sign-in
- "Remember me" on this computer: a random token in the Windows user's data
  folder, only its hash in the database; 30 days; replaced at every use.
  Logging out, a new password or a stopped user ends it. The owner can end a
  user's remembered sign-ins or turn the option off for everyone.

Printing
- Signature block: for each party a line to sign on and a line for the date.
- Dates, numbers and codes print as separate runs beside their Arabic labels
  (they could come out reordered), and the page keeps the printer's own
  margins so nothing at the foot of the page is cut off.

Screens
- Scrollbars always shown, wider, draggable, on the right edge.
- A trail at the top (section › page) with a back button (also Alt + →);
  clearer back buttons on record and document pages.
- The audit log shows the value before and after and the reason.

## 2.3.1

No database change.

- Products: "تحديد وتصنيف" (select and categorise). Tick products one by
  one, or filter and search (for example a brand + "بدون تصنيف" + the word
  "حوض") and "select all shown", then give them all one category and
  subcategory in one step. A new category or subcategory can be made from
  the same window. Each changed product is in the audit log with its old and
  new category. Buying and selling discounts on that category apply at once.
- Products: the category filter has "بدون تصنيف" (no category), with the
  count, to find what still needs one.
- Price list import: a known product with no category takes the category
  (and subcategory) from the file's columns; a category already chosen is
  never changed. The preview shows how many products get one.

## 2.3.0

The last blueprint items; everything except the Shopify connection is in.
Database schema 19 (new columns and two tables; nothing removed).

- Purchase planning (4.1), from the purchase orders screen: per product the
  sellable stock, reserved, on order, minimum, sales over 30 / 60 / 90 days
  and a suggested quantity covering sales over the supplier's lead time plus
  safety days. Every supplier with a recorded discount on the brand is
  listed with its net cost and lead time, cheapest first. The chosen lines
  are saved as one draft purchase order per supplier, approved as usual.
- Suppliers: email, tax number and usual lead time.
- Customer file (6.1): email, tax number, payment terms and contacts
  (name, role, phone, email). A credit invoice gets its due date from the
  terms; it shows on the invoice and its print, and aging counts from it.
  The customer and supplier Excel import reads the new columns.
- Expenses (9.1): payee, receipt number, recoverable input VAT (posted to
  input VAT, kept out of the expense, the profit and project costs, shown in
  the VAT report) and a scan or PDF of the receipt kept inside the database.
- Reservations (5.3): cancelled when their order is cancelled; an active
  hold past its day shows as expired; states shown on the customer page.
- Backups (9.3): a timed backup every two hours while the program is open;
  the newest 10 timed and the newest 10 other backups are kept.
- Guides: the user guide, the application guide, the customer demo and the
  handover checklist describe this version.

## 2.2.1

No database change.

- Fix: a new purchase order, sales order or quotation took only one
  product, because the product search kept the first product's name. The
  forms now work like the invoice: the search clears after each pick,
  "Browse products" (F3) adds products from photos and categories, picking a
  product again adds one more of it, and the lines show in a table with the
  stock, list price, quantity (and extra discount on sales) and the total at
  list price. Saving with no products is refused.
- "New quotation" button on the sales orders screen, beside "New order".
- Purchase invoice: "Browse products" (F3) as on the sales invoice, showing
  all products (not only those in stock); a product picked again adds one
  more to its line.

## 2.2.0

The remaining blueprint items, except the Shopify connection. Database
schema 18 (new tables and columns; nothing removed).

- Quotations (6.2): a last valid day (14 days by default, changeable);
  an expired quotation is confirmed only by the owner; "new revision" copies
  it with the next revision number and keeps the old one as "revised".
- Receiving (4.2): accepted and rejected quantities with the reason and
  inspection note; rejected goods never enter stock or the supplier's
  account, and the order line stays open for them; a record of rejections.
- Direct supply from the supplier (5.3): on a sale line, choose the
  supplier and their cost; no stock is used, a direct purchase invoice owes
  the supplier, and the cost goes to the cost of that sale. The same product
  can be on two lines, one from stock and one direct. Cancelling the sale
  cancels the direct purchase.
- Input VAT on purchase invoices: owed to the supplier, kept out of the
  goods' cost, posted to input VAT and shown in the VAT report.
- Delivery (6.4): pickup, delivery or direct; address, carrier and a fee
  charged to the customer (on the invoice, as delivery income); a deliveries
  screen with preparing / shipped / delivered and proof of delivery; shown
  and printed on the invoice.
- Leads (6.1): possible customers with source, interest, expected value,
  stage, next follow-up and a lost reason; conversion to a customer.
- Expense plans (9.1): recurring expenses as reminders, recorded once when
  paid; Excel import of past expenses with a preview, their original dates,
  date and amount checks and duplicate detection.
- Soft close (9.3): while a month is reviewed only the owner and the
  accountant can record or cancel in it; then the final close.
- A delivery-income account is added to the chart; existing charts get it
  on first start.

## 2.1.0

Finishing round: new screens, roles, stock count and a full reports page.
No database change.

- Fix: the period closing tab loaded forever when no period was closed yet.
- New invoice: "Browse products" (F3) with photos, categories, brands, stock
  and list price; each tap adds the product or one more of it, the count
  shows on the photo. An empty invoice offers the best sellers in one tap.
  The customer's balance shows beside their name, red when the invoice
  would pass the credit limit.
- Customers and suppliers lists: figures on top (active, owed, over limit,
  year's sales or purchases), filters with counts (owing, over limit, credit,
  stopped), category filter, sorting by balance, last dealing or year's
  total, avatar and phone in one cell, last purchase, credit-limit usage
  bar, quick actions per row, and a card view.
- Products: figures (active, in stock, under minimum, without a price in
  force), filters (in stock, low, out, no price, stopped), category and
  brand menus, list price and stock state on each row, and a photo card view.
- Inventory: figures (items, value, low, old-price stock, sold out), filters,
  places as chips, a new/old price bar per item, sellable stock.
- Price lists: page header, tabs with icons, figures (lists in force, brands,
  priced products, rows waiting review), filters by state, search, and cards
  with the state, brand, VAT state and a matched/review bar.
- Reports: grouped catalogue with search and descriptions; key figures, a
  chart view and the table for each report. New reports: monthly sales,
  sales by category, by brand and by user, profit by product and by
  customer, projects, purchases by supplier and by product, slow-moving
  stock.
- Roles (blueprint 9.3): owner, accountant, purchasing, warehouse, sales /
  cashier and read-only, each with its own screens and rights; cost and
  profit only for owner, accountant and purchasing; approvals and reopening
  a closed period stay with the owner; read-only users record nothing.
- Stock count (blueprint 5.1): count one place, see each difference and its
  value, and post all differences as adjustments in one step with a reason;
  the books follow.
- The Arabic user guide covers accounting, projects, roles and the new
  screens.

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
