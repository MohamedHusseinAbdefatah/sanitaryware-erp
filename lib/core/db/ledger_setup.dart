// The ledger's starting chart of accounts and its database triggers.
//
// Triggers do two jobs, so that no way of changing a document can get around
// them: they put every changed document in `ledger_queue` (its entry is then
// built again), and they refuse to add or cancel a document dated inside a
// closed period.
import 'package:drift/drift.dart';

import 'database.dart';

/// The setting holding the last closed day (seconds since 1970); nothing on
/// or before it can be added or cancelled.
const booksLockedUntilKey = 'books_locked_until';

/// The text a refused change carries; the screens turn it into a message.
const periodLockedMarker = 'PERIOD_LOCKED';

/// (code, Arabic name, kind, parent code, is a heading, system key)
const starterChart = <(String, String, String, String?, bool, String?)>[
  ('1', 'الأصول', 'asset', null, true, null),
  ('11', 'الأصول المتداولة', 'asset', '1', true, null),
  ('1101', 'الخزنة (نقدية)', 'asset', '11', false, 'cash'),
  ('1102', 'البنك', 'asset', '11', false, 'bank'),
  ('1103', 'شيكات تحت التحصيل', 'asset', '11', false, 'cheques_in'),
  ('1110', 'العملاء', 'asset', '11', false, 'ar'),
  ('1120', 'المخزون', 'asset', '11', false, 'inventory'),
  ('1130', 'دفعات مقدمة للموردين', 'asset', '11', false, 'supplier_advances'),
  ('1140', 'مصروفات مدفوعة مقدماً', 'asset', '11', false, null),
  ('1150', 'ضريبة القيمة المضافة - مدخلات', 'asset', '11', false, 'vat_in'),
  ('12', 'الأصول الثابتة', 'asset', '1', true, null),
  ('1201', 'أثاث وديكور المعرض', 'asset', '12', false, null),
  ('1202', 'معدات وأجهزة', 'asset', '12', false, null),
  ('1203', 'سيارات', 'asset', '12', false, null),
  ('1209', 'مجمع الإهلاك', 'asset', '12', false, null),
  ('2', 'الالتزامات', 'liability', null, true, null),
  ('21', 'الالتزامات المتداولة', 'liability', '2', true, null),
  ('2101', 'الموردون', 'liability', '21', false, 'ap'),
  ('2102', 'شيكات صادرة لم تُصرف', 'liability', '21', false, 'cheques_out'),
  ('2110', 'دفعات مقدمة من العملاء', 'liability', '21', false, 'customer_advances'),
  ('2120', 'ضريبة القيمة المضافة - مخرجات', 'liability', '21', false, 'vat_out'),
  ('2130', 'مصاريف شراء مستحقة لجهات أخرى', 'liability', '21', false, 'purchase_costs'),
  ('2140', 'مصروفات مستحقة', 'liability', '21', false, null),
  ('22', 'الالتزامات طويلة الأجل', 'liability', '2', true, null),
  ('2201', 'قروض', 'liability', '22', false, null),
  ('2202', 'أقساط طويلة الأجل', 'liability', '22', false, null),
  ('3', 'حقوق الملكية', 'equity', null, true, null),
  ('3101', 'رأس المال', 'equity', '3', false, 'capital'),
  ('3102', 'مسحوبات المالك', 'equity', '3', false, 'drawings'),
  ('3103', 'أرصدة افتتاحية', 'equity', '3', false, 'opening'),
  ('3201', 'الأرباح المحتجزة', 'equity', '3', false, 'retained'),
  ('4', 'الإيرادات', 'income', null, true, null),
  ('4101', 'المبيعات', 'income', '4', false, 'sales'),
  ('4102', 'مرتجعات ومسموحات المبيعات', 'income', '4', false, 'sales_returns'),
  ('4201', 'إيرادات أخرى', 'income', '4', false, 'other_income'),
  ('4202', 'أرباح تسوية المخزون', 'income', '4', false, 'stock_gain'),
  ('5', 'التكاليف والمصروفات', 'expense', null, true, null),
  ('51', 'تكلفة المبيعات', 'expense', '5', true, null),
  ('5101', 'تكلفة البضاعة المباعة', 'expense', '51', false, 'cogs'),
  ('5102', 'فروق مرتجعات المشتريات', 'expense', '51', false, 'purchase_variance'),
  ('5103', 'خسائر تسوية المخزون', 'expense', '51', false, 'stock_loss'),
  ('52', 'المصروفات التشغيلية', 'expense', '5', true, 'expenses_group'),
  ('5299', 'مصروفات أخرى', 'expense', '52', false, 'other_expense'),
  ('53', 'مصروفات أخرى غير تشغيلية', 'expense', '5', true, null),
  ('5301', 'الإهلاك', 'expense', '53', false, null),
  ('5302', 'مصروفات بنكية وفوائد', 'expense', '53', false, null),
];

Future<void> seedChart(AppDatabase db) async {
  final row = await db.customSelect('SELECT COUNT(*) AS c FROM accounts').getSingle();
  if (row.read<int>('c') > 0) return;
  final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
  final ids = <String, int>{};
  for (final (code, name, kind, parent, group, key) in starterChart) {
    final id = await db.customInsert(
      'INSERT INTO accounts (code, name_ar, kind, parent_id, is_group, system_key, is_active, created_at, updated_at) '
      'VALUES (?, ?, ?, ?, ?, ?, 1, ?, ?)',
      variables: [
        Variable.withString(code),
        Variable.withString(name),
        Variable.withString(kind),
        Variable<int>(parent == null ? null : ids[parent]),
        Variable.withBool(group),
        Variable<String>(key),
        Variable.withInt(now),
        Variable.withInt(now),
      ],
    );
    ids[code] = id;
  }
}

/// Triggers that keep the ledger and the closed periods. Safe to run again.
Future<void> installLedgerTriggers(AppDatabase db) async {
  String queue(String type, String id) => "INSERT OR IGNORE INTO ledger_queue (ref_type, ref_id) VALUES ('$type', $id);";
  final statements = <String>[
    for (final (table, type, idExpr) in const [
      ('sales_invoices', 'sales_invoice', 'NEW.id'),
      ('sales_invoice_items', 'sales_invoice', 'NEW.invoice_id'),
      ('purchase_invoices', 'purchase_invoice', 'NEW.id'),
      ('purchase_invoice_items', 'purchase_invoice', 'NEW.invoice_id'),
      ('payments', 'payment', 'NEW.id'),
      ('cheques', 'payment', 'NEW.payment_id'),
      ('returns', 'return', 'NEW.id'),
      ('return_items', 'return', 'NEW.return_id'),
      ('expenses', 'expense', 'NEW.id'),
    ]) ...[
      'CREATE TRIGGER IF NOT EXISTS lq_${table}_ins AFTER INSERT ON $table BEGIN ${queue(type, idExpr)} END',
      'CREATE TRIGGER IF NOT EXISTS lq_${table}_upd AFTER UPDATE ON $table BEGIN ${queue(type, idExpr)} END',
    ],
    "CREATE TRIGGER IF NOT EXISTS lq_stock_ins AFTER INSERT ON stock_movements "
        "WHEN NEW.type IN ('adjustment', 'opening') BEGIN ${queue('stock_movement', 'NEW.id')} END",
    "CREATE TRIGGER IF NOT EXISTS lq_layer_ins AFTER INSERT ON layer_consumptions "
        "WHEN NEW.ref_type = 'adjustment' AND NEW.ref_id IS NOT NULL BEGIN ${queue('stock_movement', 'NEW.ref_id')} END",
    'CREATE TRIGGER IF NOT EXISTS lq_customers_ins AFTER INSERT ON customers BEGIN ${queue('customer_opening', 'NEW.id')} END',
    'CREATE TRIGGER IF NOT EXISTS lq_customers_upd AFTER UPDATE OF opening_balance ON customers '
        'BEGIN ${queue('customer_opening', 'NEW.id')} END',
    'CREATE TRIGGER IF NOT EXISTS lq_suppliers_ins AFTER INSERT ON suppliers BEGIN ${queue('supplier_opening', 'NEW.id')} END',
    'CREATE TRIGGER IF NOT EXISTS lq_suppliers_upd AFTER UPDATE OF opening_balance ON suppliers '
        'BEGIN ${queue('supplier_opening', 'NEW.id')} END',
    // Whether pending cheques count changes every cheque payment's entry.
    "CREATE TRIGGER IF NOT EXISTS lq_settings_ins AFTER INSERT ON app_settings WHEN NEW.key_name = 'count_pending_cheques' "
        "BEGIN INSERT OR IGNORE INTO ledger_queue (ref_type, ref_id) SELECT 'payment', payment_id FROM cheques; END",
    "CREATE TRIGGER IF NOT EXISTS lq_settings_upd AFTER UPDATE ON app_settings WHEN NEW.key_name = 'count_pending_cheques' "
        "BEGIN INSERT OR IGNORE INTO ledger_queue (ref_type, ref_id) SELECT 'payment', payment_id FROM cheques; END",
  ];
  // An invoice made from a project's order belongs to that project too.
  statements
    ..add('CREATE TRIGGER IF NOT EXISTS prj_so_delivery AFTER INSERT ON sales_order_deliveries BEGIN '
        'UPDATE sales_invoices SET project_id = (SELECT project_id FROM sales_orders WHERE id = NEW.order_id) '
        'WHERE id = NEW.invoice_id AND project_id IS NULL; END')
    ..add('CREATE TRIGGER IF NOT EXISTS prj_po_receipt AFTER INSERT ON purchase_order_receipts BEGIN '
        'UPDATE purchase_invoices SET project_id = (SELECT project_id FROM purchase_orders WHERE id = NEW.order_id) '
        'WHERE id = NEW.invoice_id AND project_id IS NULL; END');
  // Closed periods: nothing dated on or before the closing day is added or
  // cancelled.
  const locked = "COALESCE((SELECT CAST(val AS INTEGER) FROM app_settings WHERE key_name = '$booksLockedUntilKey'), -1)";
  for (final table in ['sales_invoices', 'purchase_invoices', 'payments', 'returns', 'expenses']) {
    statements
      ..add('CREATE TRIGGER IF NOT EXISTS lock_${table}_ins BEFORE INSERT ON $table WHEN NEW.date <= $locked '
          "BEGIN SELECT RAISE(ABORT, '$periodLockedMarker'); END")
      ..add('CREATE TRIGGER IF NOT EXISTS lock_${table}_status BEFORE UPDATE OF status ON $table '
          'WHEN OLD.date <= $locked AND NEW.status <> OLD.status '
          "BEGIN SELECT RAISE(ABORT, '$periodLockedMarker'); END");
  }
  statements
    ..add("CREATE TRIGGER IF NOT EXISTS lock_stock_ins BEFORE INSERT ON stock_movements "
        "WHEN NEW.type IN ('adjustment', 'opening') AND NEW.date <= $locked "
        "BEGIN SELECT RAISE(ABORT, '$periodLockedMarker'); END")
    ..add("CREATE TRIGGER IF NOT EXISTS lock_journal_ins BEFORE INSERT ON journal_entries "
        "WHEN NEW.source = 'manual' AND NEW.date <= $locked "
        "BEGIN SELECT RAISE(ABORT, '$periodLockedMarker'); END");
  for (final s in statements) {
    await _tolerant(db, s);
  }
}

/// Puts every existing document in the queue (the first build of the ledger,
/// or a full rebuild).
Future<void> enqueueEverything(AppDatabase db) async {
  for (final (type, table) in const [
    ('sales_invoice', 'sales_invoices'),
    ('purchase_invoice', 'purchase_invoices'),
    ('payment', 'payments'),
    ('return', 'returns'),
    ('expense', 'expenses'),
    ('customer_opening', 'customers'),
    ('supplier_opening', 'suppliers'),
  ]) {
    await _tolerant(db, "INSERT OR IGNORE INTO ledger_queue (ref_type, ref_id) SELECT '$type', id FROM $table");
  }
  await _tolerant(db, "INSERT OR IGNORE INTO ledger_queue (ref_type, ref_id) "
      "SELECT 'stock_movement', id FROM stock_movements WHERE type IN ('adjustment', 'opening')");
}

/// Runs [sql], skipping it when a table it needs is not there (a partial or
/// very old file being upgraded); anything else still fails.
Future<void> _tolerant(AppDatabase db, String sql) async {
  try {
    await db.customStatement(sql);
  } catch (e) {
    if (!'$e'.contains('no such table')) rethrow;
  }
}
