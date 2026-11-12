import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/auth/session.dart';
import '../../core/dates.dart';
import '../../core/db/database.dart';
import '../../core/money.dart';
import '../../core/providers.dart';
import '../../core/services/sales_service.dart';
import '../../core/theme.dart';
import '../../core/widgets/data_list.dart';
import '../../core/widgets/feedback.dart';
import '../../core/widgets/list_kit.dart';

final _deliveriesProvider = StreamProvider.autoDispose<List<(SalesInvoice, String?)>>(
  (ref) => ref.watch(salesServiceProvider).watchDeliveries(),
);

Widget deliveryPill(String? s) => switch (s) {
      DeliveryStatus.delivered => StatusPill.good(DeliveryStatus.label(s)),
      DeliveryStatus.shipped => StatusPill(DeliveryStatus.label(s)),
      _ => StatusPill.warn(DeliveryStatus.label(s ?? DeliveryStatus.preparing)),
    };

/// Invoices that go out by delivery or straight from a supplier
/// (blueprint 6.4): address, carrier, fee, state and proof of delivery.
class DeliveriesScreen extends ConsumerStatefulWidget {
  const DeliveriesScreen({super.key});

  @override
  ConsumerState<DeliveriesScreen> createState() => _DeliveriesScreenState();
}

class _DeliveriesScreenState extends ConsumerState<DeliveriesScreen> {
  String? _show = 'open';

  Future<void> _move(SalesInvoice inv, String status) async {
    String? proof;
    if (status == DeliveryStatus.delivered) {
      final c = TextEditingController();
      proof = await showDialog<String>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text('تسليم ${inv.number}'),
          content: SizedBox(
            width: 420,
            child: TextField(
              controller: c,
              autofocus: true,
              decoration: const InputDecoration(labelText: 'إثبات التسليم: اسم المستلم / رقم الإيصال / ملاحظة'),
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('إلغاء')),
            FilledButton(onPressed: () => Navigator.pop(ctx, c.text), child: const Text('تم التسليم')),
          ],
        ),
      );
      if (proof == null || !mounted) return;
    }
    await runGuarded(context, () async {
      await ref.read(salesServiceProvider).setDeliveryStatus(inv.id, status, proof: proof, user: ref.read(currentUserProvider)!);
      return true;
    });
  }

  @override
  Widget build(BuildContext context) {
    final async = ref.watch(_deliveriesProvider);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 10, 24, 0),
        child: Row(children: [
          TextButton.icon(
            onPressed: () => context.go('/sales'),
            icon: const Icon(Icons.arrow_forward, size: 18),
            label: const Text('فواتير البيع'),
          ),
        ]),
      ),
      const PageHeader(title: 'التوصيلات'),
      Expanded(
        child: async.when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (e, _) => Center(child: Text('$e')),
          data: (all) {
            bool pass((SalesInvoice, String?) r, String? f) => switch (f) {
                  'open' => r.$1.deliveryStatus != DeliveryStatus.delivered,
                  null => true,
                  _ => r.$1.deliveryStatus == f,
                };
            final rows = all.where((r) => pass(r, _show)).toList();
            return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              SummaryStrip(items: [
                SummaryItem('قيد التجهيز', '${all.where((r) => pass(r, DeliveryStatus.preparing)).length}',
                    icon: Icons.inventory_outlined, tone: AppColors.warn),
                SummaryItem('خرج للتوصيل', '${all.where((r) => pass(r, DeliveryStatus.shipped)).length}',
                    icon: Icons.local_shipping_outlined),
                SummaryItem('تم التسليم', '${all.where((r) => pass(r, DeliveryStatus.delivered)).length}',
                    icon: Icons.check_circle_outline, tone: AppColors.good),
                SummaryItem('رسوم توصيل محصلة', formatMoney(all.fold(0, (s, r) => s + r.$1.deliveryFee)),
                    icon: Icons.payments_outlined),
              ]),
              CountChips<String?>(
                options: [
                  ('open', 'لم يُسلّم', all.where((r) => pass(r, 'open')).length),
                  (DeliveryStatus.preparing, 'قيد التجهيز', all.where((r) => pass(r, DeliveryStatus.preparing)).length),
                  (DeliveryStatus.shipped, 'خرج للتوصيل', all.where((r) => pass(r, DeliveryStatus.shipped)).length),
                  (DeliveryStatus.delivered, 'تم التسليم', all.where((r) => pass(r, DeliveryStatus.delivered)).length),
                  (null, 'الكل', all.length),
                ],
                selected: _show,
                onSelected: (v) => setState(() => _show = v),
              ),
              Expanded(
                child: DataList<(SalesInvoice, String?)>(
                  rows: rows,
                  emptyText: 'لا توجد توصيلات هنا. اختر طريقة التسليم في الفاتورة (توصيل أو توريد مباشر).',
                  onTap: (r) => context.go('/sales/${r.$1.id}'),
                  trailing: (r) => r.$1.deliveryStatus == DeliveryStatus.delivered
                      ? const SizedBox()
                      : PopupMenuButton<String>(
                          tooltip: 'تحديث الحالة',
                          onSelected: (s) => _move(r.$1, s),
                          itemBuilder: (_) => [
                            for (final s in DeliveryStatus.all)
                              if (s != r.$1.deliveryStatus) PopupMenuItem(value: s, child: Text(DeliveryStatus.label(s))),
                          ],
                        ),
                  columns: [
                    DataListColumn('الفاتورة', (r) => TitleCell(r.$1.number, subtitle: formatDate(r.$1.date))),
                    DataListColumn('العميل', flex: 2, (r) => Text(r.$2 ?? 'نقدي')),
                    DataListColumn('الطريقة', flex: 2, (r) => Text(DeliveryMethod.label(r.$1.deliveryMethod))),
                    DataListColumn('العنوان / الناقل', flex: 3, (r) => TitleCell(r.$1.deliveryAddress ?? '—', subtitle: r.$1.carrier)),
                    DataListColumn('الرسوم', numeric: true, (r) => Text(r.$1.deliveryFee == 0 ? '—' : formatMoney(r.$1.deliveryFee))),
                    DataListColumn('الحالة', numeric: true, flex: 2, (r) => Column(mainAxisSize: MainAxisSize.min, children: [
                          deliveryPill(r.$1.deliveryStatus),
                          if (r.$1.deliveredAt != null)
                            Text('${formatDate(r.$1.deliveredAt!)} — ${r.$1.deliveryProof ?? ''}',
                                overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 11, color: AppColors.muted)),
                        ])),
                  ],
                ),
              ),
            ]);
          },
        ),
      ),
    ]);
  }
}
