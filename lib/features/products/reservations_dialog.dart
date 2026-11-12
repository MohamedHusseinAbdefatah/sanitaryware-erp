import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/auth/session.dart';
import '../../core/l10n/strings.dart';
import '../../core/providers.dart';
import '../../core/quantity.dart';
import '../../core/services/reservation_service.dart';
import '../../core/widgets/feedback.dart';

final _activeReservationsProvider = StreamProvider.autoDispose<List<ReservationRow>>(
    (ref) => ref.watch(reservationServiceProvider).watchActive());

/// Stock held for customers. Reservations are not typed by hand: confirming a
/// customer's sales order holds what is in stock, and goods ordered from a
/// supplier for that order are held when they arrive. Delivering or
/// cancelling the order gives them back.
class ReservationsDialog extends ConsumerWidget {
  const ReservationsDialog({super.key});

  Future<void> _release(BuildContext context, WidgetRef ref, ReservationRow r) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('فك الحجز'),
        content: Text('فك حجز ${formatQty(r.reservation.qty)} من "${r.productName}"'
            '${r.customerName == null ? '' : ' للعميل ${r.customerName}'}؟ تصبح الكمية متاحة للبيع لأي عميل.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('رجوع')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('فك الحجز')),
        ],
      ),
    );
    if (ok != true || !context.mounted) return;
    await runGuarded(context, () async {
      await ref.read(reservationServiceProvider).release(r.reservation.id, userId: ref.read(currentUserProvider)?.id);
      return true;
    });
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final rows = ref.watch(_activeReservationsProvider).valueOrNull ?? const <ReservationRow>[];
    final theme = Theme.of(context);
    return AlertDialog(
      title: const Text('الحجوزات'),
      content: SizedBox(
        width: 680,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                padding: const EdgeInsets.all(10),
                color: theme.colorScheme.surfaceContainerHighest,
                child: const Text(
                  'الحجز يتم تلقائياً من أوامر البيع: عند تأكيد أمر بيع يُحجز الموجود في المخزن للعميل، '
                  'والناقص يُطلب من المورد بأمر شراء من شاشة أوامر البيع، ويُحجز للعميل عند وصوله. '
                  'التسليم أو إلغاء الأمر يفك الحجز.',
                ),
              ),
              const SizedBox(height: 12),
              if (rows.isEmpty) const Padding(padding: EdgeInsets.all(8), child: Text('لا توجد حجوزات')),
              for (final r in rows)
                ListTile(
                  dense: true,
                  leading: const Icon(Icons.bookmark_outline),
                  title: Text('${r.productName} — ${formatQty(r.reservation.qty)}'),
                  subtitle: Text([
                    if (r.customerName != null) r.customerName!,
                    if (r.orderNumber != null) 'أمر البيع ${r.orderNumber}',
                    if (r.reservation.note != null && r.orderNumber == null) r.reservation.note!,
                  ].join(' • ')),
                  trailing: TextButton(onPressed: () => _release(context, ref, r), child: const Text('فك الحجز')),
                ),
            ],
          ),
        ),
      ),
      actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text(Strings.close))],
    );
  }
}
