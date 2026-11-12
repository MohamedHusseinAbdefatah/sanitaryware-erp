// Builds docs/application_guide_en.pdf, the developer and owner reference for
// what the program does. Rebuild it with every release:
//
//   flutter test tool/docs/screenshots_test.dart
//   flutter test tool/docs/app_guide_test.dart
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:sanitaryware_erp/core/db/database.dart';
import 'package:sanitaryware_erp/core/printing/pdf_fonts.dart';
import 'package:sanitaryware_erp/core/version.dart';

/// A block of the guide: a heading, paragraphs, bullets, a table, a picture.
sealed class _B {
  const _B();
}

class _H extends _B {
  const _H(this.text, {this.level = 1});
  final String text;
  final int level;
}

class _P extends _B {
  const _P(this.text);
  final String text;
}

class _L extends _B {
  const _L(this.items);
  final List<String> items;
}

class _T extends _B {
  const _T(this.header, this.rows, {this.widths});
  final List<String> header;
  final List<List<String>> rows;
  final List<double>? widths;
}

class _S extends _B {
  const _S(this.file, this.caption);
  final String file;
  final String caption;
}

class _Page extends _B {
  const _Page();
}

final _content = <_B>[
  const _H('1. What the program is'),
  const _P('Instalux ERP is an offline, Arabic, right-to-left Windows program that runs a sanitaryware supply '
      'business on one PC: products and price lists, stock in several places with FIFO costing, customers and '
      'suppliers, buying, selling, quotations and orders, payments and cheques, returns, expenses, reports and '
      'backup. This guide describes version $appVersion (database schema ${AppDatabase.latestSchemaVersion}).'),
  const _P('Built for one company, one PC and one currency (Egyptian pounds). There is no internet, server or '
      'cloud account. The data lives in one database file on that PC, and backups are copied to a second folder.'),
  const _H('Rules that keep the numbers right', level: 2),
  const _T(['Rule', 'What it means'], [
    ['Money is whole piastres', '1 EGP = 100 piastres, stored as integers. No decimals, so no rounding drift.'],
    ['Quantities are thousandths', '1.5 metres is stored as 1500. Pieces must be whole; metres may have decimals.'],
    ['Percentages are basis points', '21% is 2100. A discount takes price x bp / 10000, rounded half up.'],
    ['Stock is never typed in', 'Stock is the sum of stock movements, per place. Every document adds movements.'],
    ['Cost comes from FIFO lots', 'Each receipt is a lot with its actual cost. Sales use the oldest lots first.'],
    ['Records are never deleted', 'A wrong document is cancelled with a reason and stays on record.'],
    ['One transaction per change', 'Anything touching money or stock is saved completely or not at all.'],
    ['Nothing is invented', 'A missing price, discount, VAT rate or cost stays empty until a person supplies it.'],
  ], widths: [1.4, 3]),
  const _H('What the program can do', level: 2),
  const _L([
    'Products as master data only: fixed Product ID, maker code kept as text, brand, category and subcategory, '
        'series, variant, finish, dimensions, unit, barcode, specs, verified VAT basis and rate, and a photo '
        '(shrunk to a small JPEG and kept inside the database, so backups carry it; thumbnails in the lists).',
    'Price lists as dated versions (Price List ID, brand, list type, period, source, VAT status), with full Excel '
        'import, single or small-group entry, a review queue, and price history per product. An "Arabic name" '
        'column names new products in Arabic (the English kept as description) and fills the Arabic name of '
        'products named only in English; an Arabic name already there is never replaced.',
    'Buying policies (supplier + brand + list) apart from selling discounts by customer category (retail, '
        'wholesale, projects, engineers, or any the owner adds), with optional special discounts by brand, '
        'category or product. Product before category before all.',
    'Stock in several places (main warehouse, showroom storage, display) with transfers that keep cost and date, '
        'reservations, and display-only places that are never sold from.',
    'Stock at the old and the new price: every lot remembers the list version it came in under.',
    'Sales invoices with a review before approval (list price, each discount and source, VAT, FIFO cost, profit, '
        'margin, markup), quotations and sales orders with a price lock, delivered in parts.',
    'Purchase invoices and purchase orders with a cost lock, received in parts into a chosen place.',
    'Returns both ways, payments and cheques, advances on orders, account statements, expenses.',
    'Fourteen reports with Excel and PDF output, a dashboard, approvals log, audit trail with before and after values.',
    'Users with two roles, automatic backups with a second folder, restore, Excel import of products, customers, suppliers.',
  ]),
  const _Page(),
  const _H('2. Users, roles and sign-in'),
  const _P('The first start shows a setup screen: company name, address and phone, then the first administrator. '
      'After that every start shows the login screen. Passwords are stored only as salted PBKDF2 hashes; every '
      'login, failed login and change is written to the audit trail.'),
  const _T(['Area', 'Administrator', 'Cashier'], [
    ['Dashboard, customers, sales, returns, payments', 'Yes', 'Yes'],
    ['Inventory', 'Adjust stock, reservations, places, value at cost', 'View and stock card'],
    ['Products (catalogue)', 'Create and edit', 'View'],
    ['Suppliers, purchases, purchase orders, price lists, policies', 'Yes', 'No'],
    ['Expenses, reports, settings, users, backup, import', 'Yes', 'No'],
    ['Price not from an approved list', 'Allowed, logged', 'Refused'],
    ['Discount past the policy limit, margin under the minimum', 'Allowed, logged', 'Refused'],
    ['Sale below FIFO cost', 'With a written reason, logged', 'Refused'],
    ['Customer over the credit limit', 'Allowed, logged', 'Refused'],
    ['Cost, profit and margin on screen', 'Shown', 'Hidden'],
  ], widths: [2.4, 1.4, 1.2]),
  const _P('A cashier who types an admin address is sent back to the dashboard. If nobody can sign in, the '
      'developer runs reset_password.bat with the program closed: it backs up the database, sets a new password '
      'and re-activates the user.'),
  const _H('3. The main window'),
  const _P('A dark sidebar on the right lists the screens in three groups: daily work (sales, customers, returns, '
      'payments), stock and buying (inventory, products, suppliers, purchases, price lists) and finance and admin (expenses, '
      'reports, settings). The top bar shows the date and a "new sale" button; F9 opens a new sale from anywhere.'),
  const _S('02_dashboard', 'Dashboard'),
  const _T(['Dashboard part', 'What it shows'], [
    ['Quick actions', 'Fast sale, receive from a customer, sale return; for the admin a purchase invoice and reports.'],
    ['Attention strip', 'Missing outside backup, items under minimum, cheques due within a week, price lists waiting '
        'for review, stopped price rows, stock whose price list is unknown. Each opens its screen.'],
    ['Figure cards', 'Today\'s sales and money received, this month\'s sales against last month, what customers owe; '
        'for the admin also gross profit this month, stock value at FIFO cost and what is owed to suppliers.'],
    ['Charts and lists', 'Sales for the last 14 days, best sellers this month, items under minimum, top debtors.'],
  ], widths: [1.2, 3.4]),
  const _Page(),
  const _H('4. Inventory, products and places'),
  const _S('15_inventory', 'Inventory: only the stock the shop holds'),
  const _P('The Inventory screen lists only products that came into stock (a purchase, opening stock, an adjustment '
      'or a return), never the whole catalogue loaded from price lists. Each row shows the balance, where it is, how '
      'much is at the new and the old list price, the last receipt and, for the admin, the value at FIFO cost; the '
      'total value is at the top. Filters: search, category, brand, under minimum, and "include sold out". '
      'Reservations and places and transfers open from this screen.'),
  const _S('03_products', 'Products: the catalogue, including everything loaded from price lists'),
  const _L([
    'Product ID: given automatically when left blank (P-000001 ...) and never changes. The maker\'s code is kept '
        'exactly as text. The same maker\'s code under the same brand and variant is refused as a duplicate.',
    'The match key used for search and duplicates ignores spaces, letter case and Arabic digits, but keeps '
        'leading zeros and hyphens: "0123" is not "123".',
    'The product holds no price, cost or balance. Prices live in price list versions, cost in FIFO lots.',
    'Opening stock needs quantity, actual cost and place, and makes a movement and a FIFO lot.',
    'Places: the main warehouse (always there) and others with a kind, a sellable flag and an active flag. '
        'Display-only places never count as available to sell.',
    'Transfers move stock with its original cost, received date and price list version.',
    'Stock adjustment: per place, with a reason, at the last known cost.',
    'Reservations hold stock for a customer; nobody else can buy it, and the customer\'s own purchase uses it up. '
        'They are not typed by hand: confirming a sales order holds what is in stock; what is short can be put on a '
        'draft purchase order to a supplier, tied to that customer order, and is held for the customer when it is '
        'received. Delivering a line in full or cancelling the order releases it. The admin can still release one.',
  ]),
  const _S('20_sales_order_stock', 'A sales order: held in stock, on order from a supplier, short'),
  const _H('Stock at the old and the new price', level: 2),
  const _P('Every lot remembers the price list version it came in under and that version\'s list price. Stock '
      'counts as new when its list price equals today\'s price, old when the price has changed since, and unknown '
      'when it came in before any list existed. Unknown is never guessed: an admin assigns it per product, or for '
      'a whole list at go-live. Selling always takes the oldest stock first.'),
  const _S('14_stock_by_price', 'Stock by price for one product'),
  const _Page(),
  const _H('5. Price lists and policies'),
  const _S('13_price_lists', 'Price list versions'),
  const _T(['Item', 'Behaviour'], [
    ['Version', 'Each list file is a new version with its own ID (PL-n), brand, list type, version number, '
        'currency (EGP), effective from and to, import date, source file and pages, row count and VAT status.'],
    ['Period', 'A new full version ends the previous one the day before it starts; one sent again on the same day '
        'replaces it from that day. A version for a few products leaves the earlier list open for everything else.'],
    ['Same type, new version', 'Only the same brand and list type make a new version. The import shows the brand\'s '
        'list types to pick from and warns in red when a new type would make a separate list. A new version takes '
        'over the active buying policies of the one it follows, with the same discounts. The format to prepare is '
        'in docs/price_list_format_ar.pdf, with two templates in docs/templates.'],
    ['Never overwritten', 'A product priced in a version cannot be changed in it. A mistaken version is withdrawn, '
        'never deleted, and documents keep using what they used.'],
    ['Full import', 'Excel with a name and a price column, and the maker\'s code when the list has one. Known '
        'products get a price, new ones a Product ID, duplicates and ambiguous rows stop in the review queue. A list '
        'with no codes matches by exact name within the brand and colour.'],
    ['PDF import', 'A supplier PDF with real text is read page by page: codes, prices and the English description. '
        'Price columns come from the headers (White, Pergamon, Colours, Price) or from where prices line up; the '
        'person ticks the columns to take and names each one by its colour. A number under no column stops the row '
        'for review with its page. Scanned pages (pictures) are refused, never guessed. The PDF is kept with the version.'],
    ['Small entry', 'A product or a few, into an existing version or a new dated one, with no file.'],
    ['Review queue', 'Link a stopped row to a product, make a new product, or skip it with a reason.'],
    ['Buying policy', 'Supplier + brand + list, scope all, category or product, base and extra discount. '
        'Without a policy no discount is assumed and the cost is typed.'],
    ['Customer category', 'Retail, wholesale, projects and contractors, engineers, and any the owner adds, each with '
        'a usual discount. Every customer has one; a walk-in sale is retail. Not tied to a list version.'],
    ['Special selling discount', 'Customer category + brand (or every brand), scope all, category or product, a '
        'discount that replaces the usual one, optional maximum discount and minimum margin. The brand rule beats '
        'the every-brand rule at the same scope. The customer\'s own discount and the negotiation add on top: '
        '21% + 1 point = 22%.'],
  ], widths: [1.1, 3.6]),
  const _Page(),
  const _H('6. Selling'),
  const _S('04_sale_entry', 'Fast sale screen'),
  const _L([
    'Type a code, name or barcode and press Enter; the quantity takes focus. Ctrl+S saves, Ctrl+P saves and prints.',
    'Each line starts at the approved list price with the policy and customer discount filled in. When several '
        'lists can price a product the cashier chooses one; with none, only an admin can type a price.',
    'The invoice discount is typed as an amount or a percent (a switch beside it) and is split over the lines '
        'exactly, for profit and tax. Purchases work the same way.',
    'Stock comes from sellable places, main warehouse first, or from the place chosen on the line.',
    'Before saving, a review shows everything about the price and, for the admin, cost and profit.',
  ]),
  const _S('15_sale_review', 'Review before approval'),
  const _P('Quotations and sales orders: draft or quotation, confirm (shows the review and locks the version, '
      'list price, discounts and VAT status), then deliver in parts; each delivery is an ordinary invoice at the '
      'locked price. An order approved on V1 keeps V1 after V2 starts. Advances received on an order move to the '
      'invoice. An outside order number can be used once per channel.'),
  const _Page(),
  const _H('7. Buying'),
  const _L([
    'Purchase invoice (admin): supplier, their invoice number, receiving place, lines, invoice discount, transport, '
        'paid now. Each line shows the list price, the supplier\'s agreed discount, an extra % for that line, and the '
        'final cost. A cost above the agreed one is marked orange and asked about before saving.',
    'Many lines at once: "from a purchase order" fills the order\'s remaining lines at their locked cost (other '
        'products can be added to the same invoice); "from a price list" ticks products of a list with quantities.',
    'Each line makes a FIFO lot at its net cost: the invoice discount is split over the lines and lowers the cost; '
        'transport and unloading are split by value and raise it. On the supplier\'s invoice they are owed to the '
        'supplier; paid to someone else they become a purchase expense that net profit does not take off twice.',
    'The supplier\'s invoice number used twice for the same supplier is asked about. Paid now: cash, bank or a '
        'cheque. What is left can have a due date; the dashboard lists supplier invoices due within a week and '
        'those overdue.',
    'Purchase orders: draft, approve (locks list, policy and cost, or takes a typed cost), receive in parts into a '
        'chosen place; each receipt is an ordinary purchase invoice. Advances to suppliers move to the invoice.',
    'Cancel (admin, with a reason): empties the lots it made, place by place; refused if the goods were sold. Its '
        'cheque and its transport expense are cancelled with it.',
  ]),
  const _S('17_purchase_entry', 'Purchase invoice: list price, agreed discount, extra %, transport'),
  const _H('Supplier advance locked to a price list', level: 2),
  const _L([
    'Money paid to a supplier ahead (e.g. 300,000), from the supplier\'s menu. It locks the price lists in force that '
        'day for the brands chosen, and the supplier\'s discount on them that day; not particular products.',
    'It counts in the supplier\'s balance at once. Each advance shows what has been taken and what is left.',
    'A purchase invoice for that supplier can be "from the advance": every line takes its locked list price and '
        'discount, whatever newer lists or discounts exist, and the invoice is paid from the advance. An invoice '
        'bigger than what is left, or a product not on the locked lists, is refused.',
    'Cancelling such an invoice gives its value back to the advance. An advance can be cancelled only while nothing '
        'has been taken; its payment cannot be cancelled from the payments screen.',
  ]),
  const _S('19_purchase_from_advance', 'A purchase taken against an advance at the locked prices'),
  const _H('8. Returns, payments, balances and expenses'),
  const _L([
    'Sale return (anyone) back into a chosen place, keeping the price list version the goods left under; purchase '
        'return (admin) leaving at that purchase\'s own cost. Refunds follow the net after the invoice discount.',
    'Payments: received from customers, paid to suppliers (admin); cash, bank or cheque; linked to an invoice or on '
        'account. Cheques: pending, cleared, bounced or cancelled.',
    'Balances are always calculated from documents: opening balance + invoices - returns + refunds - payments.',
    'Statements for any date range with a running balance; uncleared cheques listed apart.',
    'Expenses by category with date and note; cancelled with a reason, never deleted.',
  ]),
  const _S('05_sale_view', 'An invoice: print, take a payment, return, cancel'),
  const _Page(),
  const _H('9. Reports'),
  const _T(['Report', 'Answers'], [
    ['Daily sales', 'What was sold each day'],
    ['Sales by customer', 'Who bought how much'],
    ['Sales by product', 'Quantity and value per item, after the invoice discount share'],
    ['Profit', 'Net sales, exact FIFO cost of goods sold, gross profit, expenses, net profit'],
    ['Expenses by category', 'Where the money went'],
    ['Cheques due', 'Cheques in and out falling due'],
    ['Stock levels / Items under minimum', 'Quantity now; what to reorder'],
    ['Stock valuation', 'Value of stock on hand at FIFO cost'],
    ['Stock at old and new price', 'Per product: version, list price, current price, quantity, actual cost'],
    ['Stock by place', 'Per place, with what is display only, and its value'],
    ['Purchase plan', 'Minimum plus reserved less stock and open orders, with the last supplier'],
    ['Customers owing / Supplier balances', 'Who owes whom'],
  ], widths: [1.6, 3]),
  const _S('11_reports', 'Reports: on screen, to Excel, to PDF'),
  const _H('10. Backup, settings and safety'),
  const _L([
    'Backups: on demand, on closing the program, and before a restore or upgrade. The newest 10 are kept, plus a '
        'copy in an optional second folder (USB or synced). The dashboard warns when that copy is missing or old.',
    'Restore checks the zip, swaps it in at the next start, and backs up the current data first.',
    'Settings: company details and logo, negative stock, pending cheques, users, Excel import, audit trail, printer test.',
    'Audit trail: every create, update (with before and after for products, customers and suppliers), cancel, '
        'login, backup and restore. Approvals log: price override, extra discount, low margin, below cost, credit limit.',
    'Data folder: %APPDATA%\\SanitarywareERP (database, backups, logs\\errors.log, logo). Only one copy runs at a time.',
  ]),
  const _Page(),
  const _H('11. What this version does not include'),
  const _P('Measured against the Instalux ERP Business Blueprint, these are not built yet and must be agreed in '
      'writing at delivery:'),
  const _L([
    'Double-entry accounting: chart of accounts, journal entries, trial balance, balance sheet, cash flow, VAT report.',
    'VAT added to invoice totals (it is verified per list, shown and stored per line).',
    'Purchase requisitions, supplier comparison, goods receipts with accepted and rejected quantities.',
    'Customer and supplier aging, due dates and payment terms.',
    'Month closing and reopening; roles beyond Admin and Cashier.',
    'Projects and BOQ; CRM leads; quotation validity and revisions; separate delivery notes and shipping.',
    'Supplier Direct and Mixed Source sales; In Transit stock; numbered stock counts.',
    'Shopify connection.',
  ]),
  const _H('12. Technical reference'),
  const _T(['Item', 'Detail'], [
    ['Stack', 'Flutter for Windows, Dart, drift on SQLite, Riverpod, go_router, pdf, printing, excel, Inno Setup.'],
    ['Database', 'Schema ${AppDatabase.latestSchemaVersion}, upgraded step by step from every older version, each '
        'step tested on a copy of the old shape.'],
    ['Numbers', 'S- sale, P- purchase, R- payment, T- return, PO- purchase order, SO- sales order, PL- price list.'],
    ['Tests', 'Automated tests cover every service and the main screens, including the blueprint\'s worked examples, '
        'a hand-calculated acceptance script and a one-year performance test.'],
    ['Release', 'build_release.bat runs every test, builds, and makes dist\\SanitarywareERP-Setup-<version>.exe. '
        'See docs\\RELEASE_CHECKLIST.md.'],
  ], widths: [1, 4]),
];

void main() {
  test('build docs/application_guide_en.pdf', () async {
    ByteData font(String name) => ByteData.sublistView(File('assets/fonts/$name').readAsBytesSync());
    final fonts = PdfFonts.fromBytes(regular: font('Cairo-Regular.ttf'), bold: font('Cairo-Bold.ttf'));
    const teal = PdfColor.fromInt(0xFF0E7C86);
    const dark = PdfColor.fromInt(0xFF0B3B40);
    const grey = PdfColor.fromInt(0xFF5C7175);
    const line = PdfColor.fromInt(0xFFDCE4E6);
    final theme = pw.PageTheme(
      pageFormat: PdfPageFormat.a4,
      margin: const pw.EdgeInsets.fromLTRB(44, 40, 44, 40),
      theme: fonts.theme.copyWith(defaultTextStyle: const pw.TextStyle(fontSize: 10.5, lineSpacing: 2)),
    );
    pw.MemoryImage shot(String name) => pw.MemoryImage(File('docs/screenshots/$name.png').readAsBytesSync());

    final doc = pw.Document(theme: fonts.theme, title: 'Instalux ERP: Application Guide $appVersion');
    final now = DateTime.now();
    doc.addPage(pw.Page(
      pageTheme: theme,
      build: (_) => pw.Column(
        mainAxisAlignment: pw.MainAxisAlignment.center,
        crossAxisAlignment: pw.CrossAxisAlignment.start,
        children: [
          pw.Container(width: 56, height: 6, color: teal),
          pw.SizedBox(height: 18),
          pw.Text('Instalux ERP', style: pw.TextStyle(fontSize: 36, fontWeight: pw.FontWeight.bold, color: dark)),
          pw.Text('Application Guide', style: const pw.TextStyle(fontSize: 22, color: grey)),
          pw.SizedBox(height: 18),
          pw.Text('Version $appVersion  |  database schema ${AppDatabase.latestSchemaVersion}  |  '
              '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}'),
          pw.SizedBox(height: 30),
          pw.Image(shot('02_dashboard'), width: 420),
        ],
      ),
    ));
    final body = <pw.Widget>[];
    for (final b in _content) {
      switch (b) {
        case _H(:final text, :final level):
          body.add(pw.Padding(
            padding: pw.EdgeInsets.only(top: level == 1 ? 14 : 10, bottom: 6),
            child: pw.Text(text,
                style: pw.TextStyle(
                  fontSize: level == 1 ? 17 : 13,
                  fontWeight: pw.FontWeight.bold,
                  color: level == 1 ? dark : teal,
                )),
          ));
        case _P(:final text):
          body.add(pw.Padding(padding: const pw.EdgeInsets.only(bottom: 6), child: pw.Text(text)));
        case _L(:final items):
          for (final i in items) {
            body.add(pw.Padding(
              padding: const pw.EdgeInsets.only(bottom: 3, left: 6),
              child: pw.Row(
                crossAxisAlignment: pw.CrossAxisAlignment.start,
                children: [pw.Text('-  ', style: const pw.TextStyle(color: teal)), pw.Expanded(child: pw.Text(i))],
              ),
            ));
          }
          body.add(pw.SizedBox(height: 4));
        case _T(:final header, :final rows, :final widths):
          body.add(pw.Padding(
            padding: const pw.EdgeInsets.only(bottom: 8),
            child: pw.TableHelper.fromTextArray(
              headers: header,
              data: rows,
              border: pw.TableBorder.all(color: line, width: .6),
              headerStyle: pw.TextStyle(fontWeight: pw.FontWeight.bold, color: PdfColors.white, fontSize: 10),
              headerDecoration: const pw.BoxDecoration(color: dark),
              cellStyle: const pw.TextStyle(fontSize: 9.5),
              cellAlignment: pw.Alignment.topLeft,
              headerAlignment: pw.Alignment.centerLeft,
              cellPadding: const pw.EdgeInsets.symmetric(horizontal: 6, vertical: 4),
              columnWidths: widths == null
                  ? null
                  : {for (var k = 0; k < widths.length; k++) k: pw.FlexColumnWidth(widths[k])},
            ),
          ));
        case _S(:final file, :final caption):
          body.add(pw.Container(
            margin: const pw.EdgeInsets.only(top: 4, bottom: 2),
            decoration: pw.BoxDecoration(border: pw.Border.all(color: line, width: .6)),
            child: pw.Image(shot(file), fit: pw.BoxFit.contain, height: 250),
          ));
          body.add(pw.Padding(
            padding: const pw.EdgeInsets.only(bottom: 8),
            child: pw.Text(caption, style: const pw.TextStyle(fontSize: 9, color: grey)),
          ));
        case _Page():
          body.add(pw.NewPage());
      }
    }
    doc.addPage(pw.MultiPage(
      pageTheme: theme,
      maxPages: 60,
      footer: (c) => pw.Row(
        mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
        children: [
          pw.Text('Instalux ERP: Application Guide $appVersion', style: const pw.TextStyle(fontSize: 8, color: grey)),
          pw.Text('Page ${c.pageNumber} of ${c.pagesCount}', style: const pw.TextStyle(fontSize: 8, color: grey)),
        ],
      ),
      build: (_) => body,
    ));
    final bytes = await doc.save();
    await File('docs/application_guide_en.pdf').writeAsBytes(bytes);
    expect(bytes.length, greaterThan(100000));
  });
}
