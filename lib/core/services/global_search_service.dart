import 'package:drift/drift.dart';

import '../dates.dart';
import '../db/database.dart';
import '../digits.dart';
import '../search_text.dart';
import 'product_service.dart';

/// What a search hit is, which decides where it opens.
enum SearchKind { product, customer, supplier, sale, purchase, project }

/// One record found by the quick search.
class SearchHit {
  const SearchHit(this.kind, this.id, this.title, this.subtitle);

  final SearchKind kind;
  final int id;
  final String title;
  final String subtitle;
}

/// The quick search (Ctrl+K): finds products, customers, suppliers,
/// invoices and projects by name, code, model, phone or number. Read only.
/// The caller says which kinds this person may open.
class GlobalSearchService {
  GlobalSearchService(this.db);

  final AppDatabase db;

  static const _perKind = 5;

  Future<List<SearchHit>> search(String query, {required Set<SearchKind> allowed}) async {
    final q = query.trim();
    if (q.isEmpty) return const [];
    final like = '%${normalizeDigits(q)}%';
    final hits = <SearchHit>[];

    if (allowed.contains(SearchKind.product)) {
      final rows = await ProductService(db).search(q, limit: _perKind);
      for (final r in rows) {
        final p = r.product;
        hits.add(SearchHit(
          SearchKind.product,
          p.id,
          p.nameAr,
          [p.code, if ((p.modelNo ?? '').isNotEmpty) 'موديل ${p.modelNo}', if (r.brandName != null) r.brandName!].join(' · '),
        ));
      }
    }

    if (allowed.contains(SearchKind.customer)) {
      final all = await db.select(db.customers).get();
      for (final c in all.where((c) => matchesSearch(q, [c.name, c.phone, c.email])).take(_perKind)) {
        hits.add(SearchHit(SearchKind.customer, c.id, c.name, [c.phone ?? '', if (!c.isActive) 'موقوف'].where((x) => x.isNotEmpty).join(' · ')));
      }
    }

    if (allowed.contains(SearchKind.supplier)) {
      final all = await db.select(db.suppliers).get();
      for (final s in all.where((s) => matchesSearch(q, [s.name, s.phone, s.email, s.taxNumber])).take(_perKind)) {
        hits.add(SearchHit(SearchKind.supplier, s.id, s.name, s.phone ?? ''));
      }
    }

    if (allowed.contains(SearchKind.sale)) {
      final rows = await (db.select(db.salesInvoices)
            ..where((t) => t.number.like(like))
            ..orderBy([(t) => OrderingTerm.desc(t.date)])
            ..limit(_perKind))
          .get();
      for (final r in rows) {
        hits.add(SearchHit(SearchKind.sale, r.id, r.number, formatDate(r.date)));
      }
    }

    if (allowed.contains(SearchKind.purchase)) {
      final rows = await (db.select(db.purchaseInvoices)
            ..where((t) => t.number.like(like) | t.supplierInvoiceNo.like(like))
            ..orderBy([(t) => OrderingTerm.desc(t.date)])
            ..limit(_perKind))
          .get();
      for (final r in rows) {
        final theirs = (r.supplierInvoiceNo ?? '').isEmpty ? '' : ' · فاتورة المورد ${r.supplierInvoiceNo}';
        hits.add(SearchHit(SearchKind.purchase, r.id, r.number, '${formatDate(r.date)}$theirs'));
      }
    }

    if (allowed.contains(SearchKind.project)) {
      final all = await db.select(db.projects).get();
      for (final p in all.where((p) => matchesSearch(q, [p.name, p.code, p.location, p.contactName])).take(_perKind)) {
        hits.add(SearchHit(SearchKind.project, p.id, p.name, [p.code, p.location ?? ''].where((x) => x.isNotEmpty).join(' · ')));
      }
    }
    return hits;
  }
}
