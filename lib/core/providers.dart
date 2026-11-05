import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'auth/auth_service.dart';
import 'backup/backup_actions.dart';
import 'backup/backup_service.dart';
import 'db/database.dart';
import 'reports/report_service.dart';
import 'services/approval_service.dart';
import 'services/balance_service.dart';
import 'services/catalog_service.dart';
import 'services/buying_policy_service.dart';
import 'services/sale_preview_service.dart';
import 'services/selling_policy_service.dart';
import 'services/expense_service.dart';
import 'services/location_service.dart';
import 'services/party_service.dart';
import 'services/payment_service.dart';
import 'services/price_list_import_service.dart';
import 'services/price_list_service.dart';
import 'services/product_service.dart';
import 'services/purchase_service.dart';
import 'services/purchase_order_service.dart';
import 'services/reservation_service.dart';
import 'services/return_service.dart';
import 'services/sales_order_service.dart';
import 'services/sales_service.dart';
import 'services/settings_service.dart';
import 'services/statement_service.dart';
import 'services/stock_service.dart';

/// Overridden in main.dart with the opened database.
final databaseProvider = Provider<AppDatabase>(
  (ref) => throw UnimplementedError('databaseProvider must be overridden'),
);

/// Overridden in main.dart with the real database file.
final databaseFileProvider = Provider<File>(
  (ref) => throw UnimplementedError('databaseFileProvider must be overridden'),
);

/// Overridden in main.dart with the backup folder.
final backupServiceProvider = Provider<BackupService>(
  (ref) => throw UnimplementedError('backupServiceProvider must be overridden'),
);

final authServiceProvider =
    Provider<AuthService>((ref) => AuthService(ref.watch(databaseProvider)));

final settingsServiceProvider =
    Provider<SettingsService>((ref) => SettingsService(ref.watch(databaseProvider)));

final backupActionsProvider = Provider<BackupActions>(
  (ref) => BackupActions(
    db: ref.watch(databaseProvider),
    backups: ref.watch(backupServiceProvider),
    databaseFile: ref.watch(databaseFileProvider),
  ),
);

final catalogServiceProvider =
    Provider<CatalogService>((ref) => CatalogService(ref.watch(databaseProvider)));

final productServiceProvider =
    Provider<ProductService>((ref) => ProductService(ref.watch(databaseProvider)));

final stockServiceProvider =
    Provider<StockService>((ref) => StockService(ref.watch(databaseProvider)));

final partyServiceProvider =
    Provider<PartyService>((ref) => PartyService(ref.watch(databaseProvider)));

final salesServiceProvider =
    Provider<SalesService>((ref) => SalesService(ref.watch(databaseProvider)));

final balanceServiceProvider =
    Provider<BalanceService>((ref) => BalanceService(ref.watch(databaseProvider)));

final paymentServiceProvider =
    Provider<PaymentService>((ref) => PaymentService(ref.watch(databaseProvider)));

final purchaseServiceProvider =
    Provider<PurchaseService>((ref) => PurchaseService(ref.watch(databaseProvider)));

final returnServiceProvider =
    Provider<ReturnService>((ref) => ReturnService(ref.watch(databaseProvider)));

final expenseServiceProvider =
    Provider<ExpenseService>((ref) => ExpenseService(ref.watch(databaseProvider)));

final statementServiceProvider =
    Provider<StatementService>((ref) => StatementService(ref.watch(databaseProvider)));

final reportServiceProvider =
    Provider<ReportService>((ref) => ReportService(ref.watch(databaseProvider)));

final approvalServiceProvider =
    Provider<ApprovalService>((ref) => ApprovalService(ref.watch(databaseProvider)));

final salesOrderServiceProvider =
    Provider<SalesOrderService>((ref) => SalesOrderService(ref.watch(databaseProvider)));

final purchaseOrderServiceProvider =
    Provider<PurchaseOrderService>((ref) => PurchaseOrderService(ref.watch(databaseProvider)));

final reservationServiceProvider =
    Provider<ReservationService>((ref) => ReservationService(ref.watch(databaseProvider)));

final locationServiceProvider =
    Provider<LocationService>((ref) => LocationService(ref.watch(databaseProvider)));

final priceListServiceProvider =
    Provider<PriceListService>((ref) => PriceListService(ref.watch(databaseProvider)));

final priceListImportServiceProvider =
    Provider<PriceListImportService>((ref) => PriceListImportService(ref.watch(databaseProvider)));

final buyingPolicyServiceProvider =
    Provider<BuyingPolicyService>((ref) => BuyingPolicyService(ref.watch(databaseProvider)));

final sellingPolicyServiceProvider =
    Provider<SellingPolicyService>((ref) => SellingPolicyService(ref.watch(databaseProvider)));

final salePreviewServiceProvider =
    Provider<SalePreviewService>((ref) => SalePreviewService(ref.watch(databaseProvider)));
