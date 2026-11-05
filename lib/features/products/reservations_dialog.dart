import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/auth/session.dart';
import '../../core/db/database.dart';
import '../../core/l10n/strings.dart';
import '../../core/providers.dart';
import '../../core/quantity.dart';
import '../../core/services/product_service.dart';
import '../../core/services/reservation_service.dart';
import '../../core/widgets/feedback.dart';
import '../../core/widgets/pickers.dart';

final _activeReservationsProvider = StreamProvider.autoDispose<List<ReservationRow>>(
    (ref) => ref.watch(reservationServiceProvider).watchActive());

/// Hold stock back for a customer, and give it back.
class ReservationsDialog extends ConsumerStatefulWidget {
  const ReservationsDialog({super.key});

  @override
  ConsumerState<ReservationsDialog> createState() => _ReservationsDialogState();
}

class _ReservationsDialogState extends ConsumerState<ReservationsDialog> {
  ProductRow? _product;
  int? _available;
  int? _customerId;
  final _qty = TextEditingController();
  final _note = TextEditingController();

  @override
  void dispose() {
    _qty.dispose();
    _note.dispose();
    super.dispose();
  }

  Future<void> _pick(ProductRow row) async {
    final a = await ref.read(reservationServiceProvider).availableQty(row.product.id);
    if (!mounted) return;
    setState(() {
      _product = row;
      _available = a;
    });
  }

  Future<void> _reserve() async {
    final p = _product;
    final qty = parseQty(_qty.text, allowDecimal: p?.unitAllowsDecimal ?? false);
    if (p == null || qty == null || qty <= 0) {
      await showMessage(context, 'اختر الصنف وأدخل كمية صحيحة');
      return;
    }
    final user = ref.read(currentUserProvider);
    final ok = await runGuarded(context, () async {
      await ref.read(reservationServiceProvider).reserve(
            productId: p.product.id,
            qty: qty,
            customerId: _customerId,
            note: _note.text,
            userId: user?.id,
          );
      return true;
    });
    if (ok == true && mounted) {
      _qty.clear();
      _note.clear();
      await _pick(p);
    }
  }

  Future<void> _release(ReservationRow r) async {
    final user = ref.read(currentUserProvider);
    await runGuarded(context, () async {
      await ref.read(reservationServiceProvider).release(r.reservation.id, userId: user?.id);
      return true;
    });
    if (_product != null && mounted) await _pick(_product!);
  }

  @override
  Widget build(BuildContext context) {
    final rows = ref.watch(_activeReservationsProvider).valueOrNull ?? const <ReservationRow>[];
    return AlertDialog(
      title: const Text('حجز المخزون'),
      content: SizedBox(
        width: 640,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              ProductSearchField(autofocus: false, onSelected: _pick, trailing: (r) => formatQty(r.stock)),
              if (_product != null) ...[
                const SizedBox(height: 8),
                Text(_product!.product.nameAr, style: const TextStyle(fontWeight: FontWeight.bold)),
                Text('المتاح للحجز: ${formatQty(_available ?? 0)}'),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: StreamBuilder<List<Customer>>(
                        stream: ref.watch(partyServiceProvider).watchCustomers(activeOnly: true),
                        builder: (context, snap) => DropdownButtonFormField<int?>(
                          initialValue: _customerId,
                          decoration: const InputDecoration(labelText: 'العميل (اختياري)'),
                          items: [
                            const DropdownMenuItem(value: null, child: Text('بدون عميل')),
                            for (final c in snap.data ?? const <Customer>[])
                              DropdownMenuItem(value: c.id, child: Text(c.name)),
                          ],
                          onChanged: (v) => setState(() => _customerId = v),
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    SizedBox(
                      width: 110,
                      child: TextField(
                        controller: _qty,
                        keyboardType: const TextInputType.numberWithOptions(decimal: true),
                        decoration: const InputDecoration(labelText: 'الكمية'),
                      ),
                    ),
                  ],
                ),
                TextField(controller: _note, decoration: const InputDecoration(labelText: Strings.notes)),
                const SizedBox(height: 12),
                Align(
                  alignment: AlignmentDirectional.centerStart,
                  child: FilledButton.icon(
                    onPressed: _reserve,
                    icon: const Icon(Icons.bookmark_add_outlined),
                    label: const Text('حجز'),
                  ),
                ),
              ],
              const Divider(height: 28),
              Text('الحجوزات القائمة', style: Theme.of(context).textTheme.titleSmall),
              if (rows.isEmpty) const Padding(padding: EdgeInsets.all(8), child: Text('لا توجد حجوزات')),
              for (final r in rows)
                ListTile(
                  dense: true,
                  title: Text('${r.productName} — ${formatQty(r.reservation.qty)}'),
                  subtitle: Text([
                    if (r.customerName != null) r.customerName!,
                    if (r.reservation.note != null) r.reservation.note!,
                  ].join(' • ')),
                  trailing: TextButton(onPressed: () => _release(r), child: const Text('إلغاء الحجز')),
                ),
            ],
          ),
        ),
      ),
      actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text(Strings.close))],
    );
  }
}
