import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:printing/printing.dart';

import '../db/database.dart';
import '../providers.dart';
import '../services/doc_types.dart';
import '../services/payment_service.dart';
import '../services/settings_service.dart';
import '../widgets/feedback.dart';
import 'documents.dart';
import 'pdf_fonts.dart';

/// The saved logo path if the file is there; otherwise the same file name
/// in [dataDir] (the logo moved with the data folder). Null if neither.
String? logoFile(String? saved, Directory dataDir) {
  if (saved == null || saved.isEmpty) return null;
  if (File(saved).existsSync()) return saved;
  final moved = p.join(dataDir.path, p.basename(saved));
  return File(moved).existsSync() ? moved : null;
}

/// The shop's name, address, phone and logo for the top of printed pages.
Future<PrintCompany> loadPrintCompany(WidgetRef ref) async {
  final settings = ref.read(settingsServiceProvider);
  final company = await settings.company();
  final logoPath = logoFile(await settings.get(SettingKey.companyLogo), ref.read(databaseFileProvider).parent);
  final logo = logoPath == null ? null : await File(logoPath).readAsBytes();
  return PrintCompany(name: company.name, address: company.address, phone: company.phone, logo: logo);
}

/// Opens the Windows print dialog (any printer, or "Microsoft Print to PDF")
/// for a document built by [build].
Future<void> printDocument(
  BuildContext context,
  WidgetRef ref, {
  required String name,
  required Future<Uint8List> Function(PrintCompany company, PdfFonts fonts) build,
}) async {
  await runGuarded(context, () async {
    final company = await loadPrintCompany(ref);
    final fonts = await PdfFonts.load();
    await Printing.layoutPdf(name: name, onLayout: (_) => build(company, fonts));
  });
}

/// The receipt for one payment, with what it was for.
Future<ReceiptData> receiptFor(AppDatabase db, PaymentRow row) async {
  final p = row.payment;
  String? forWhat;
  if (p.invoiceRefId != null) {
    forWhat = switch (p.invoiceRefType) {
      RefType.salesInvoice =>
        'فاتورة بيع ${(await (db.select(db.salesInvoices)..where((t) => t.id.equals(p.invoiceRefId!))).getSingle()).number}',
      RefType.purchaseInvoice =>
        'فاتورة شراء ${(await (db.select(db.purchaseInvoices)..where((t) => t.id.equals(p.invoiceRefId!))).getSingle()).number}',
      RefType.returnDoc =>
        'مرتجع ${(await (db.select(db.returns)..where((t) => t.id.equals(p.invoiceRefId!))).getSingle()).number}',
      _ => null,
    };
  }
  return ReceiptData(
    number: p.number,
    date: p.date,
    received: p.direction == PaymentDirection.inbound,
    partyName: row.partyName,
    amount: p.amount,
    method: p.method,
    chequeNo: row.cheque?.chequeNo,
    bank: row.cheque?.bank,
    dueDate: row.cheque?.dueDate,
    forWhat: forWhat ?? 'تحت الحساب',
    notes: p.notes,
    cancelled: p.status == DocStatus.cancelled,
  );
}

/// Loads the invoice fresh (paid amount and balance as of now) and prints it.
Future<void> printSalesInvoice(BuildContext context, WidgetRef ref, int invoiceId) async {
  final detail = await ref.read(salesServiceProvider).detail(invoiceId);
  if (!context.mounted) return;
  await printDocument(
    context,
    ref,
    name: 'فاتورة بيع ${detail.invoice.number}',
    build: (company, fonts) => salesInvoicePdf(detail, company, fonts),
  );
}

Future<void> printPurchaseInvoice(BuildContext context, WidgetRef ref, int invoiceId) async {
  final detail = await ref.read(purchaseServiceProvider).detail(invoiceId);
  if (!context.mounted) return;
  await printDocument(
    context,
    ref,
    name: 'فاتورة شراء ${detail.invoice.number}',
    build: (company, fonts) => purchaseInvoicePdf(detail, company, fonts),
  );
}

Future<void> printReceipt(BuildContext context, WidgetRef ref, PaymentRow row) async {
  final data = await receiptFor(ref.read(databaseProvider), row);
  if (!context.mounted) return;
  await printDocument(
    context,
    ref,
    name: 'إيصال ${data.number}',
    build: (company, fonts) => receiptPdf(data, company, fonts),
  );
}
