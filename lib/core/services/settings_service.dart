import 'package:drift/drift.dart';

import '../db/database.dart';

abstract final class SettingKey {
  static const companyName = 'company_name';
  static const companyAddress = 'company_address';
  static const companyPhone = 'company_phone';
  // Optional second folder (USB drive, cloud-synced folder) for backups.
  static const backupExternalFolder = 'backup_external_folder';
}

class CompanyInfo {
  const CompanyInfo({required this.name, this.address = '', this.phone = ''});

  final String name;
  final String address;
  final String phone;
}

/// Key/value settings stored in `app_settings`.
class SettingsService {
  SettingsService(this.db);

  final AppDatabase db;

  Future<String?> get(String key) async {
    final row = await (db.select(db.appSettings)
          ..where((t) => t.keyName.equals(key)))
        .getSingleOrNull();
    return row?.val;
  }

  Future<void> set(String key, String value) {
    return db.into(db.appSettings).insertOnConflictUpdate(
          AppSettingsCompanion(keyName: Value(key), val: Value(value)),
        );
  }

  Future<CompanyInfo> company() async {
    return CompanyInfo(
      name: await get(SettingKey.companyName) ?? '',
      address: await get(SettingKey.companyAddress) ?? '',
      phone: await get(SettingKey.companyPhone) ?? '',
    );
  }

  Future<void> saveCompany(CompanyInfo info) {
    return db.transaction(() async {
      await set(SettingKey.companyName, info.name.trim());
      await set(SettingKey.companyAddress, info.address.trim());
      await set(SettingKey.companyPhone, info.phone.trim());
    });
  }
}
