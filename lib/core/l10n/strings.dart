/// All Arabic UI text lives here so it is easy to edit in one place.
class Strings {
  Strings._();

  static const appTitle = 'إدارة الأدوات الصحية';

  static const dashboard = 'لوحة التحكم';
  static const products = 'المنتجات والمخزون';
  static const customers = 'العملاء';
  static const suppliers = 'الموردون';
  static const sales = 'فواتير البيع';
  static const purchases = 'فواتير الشراء';
  static const payments = 'المدفوعات والشيكات';
  static const expenses = 'المصروفات';
  static const reports = 'التقارير';
  static const settings = 'الإعدادات';

  static const comingSoon = 'قريباً';

  // Common
  static const save = 'حفظ';
  static const cancel = 'إلغاء';
  static const confirm = 'تأكيد';
  static const required = 'مطلوب';
  static const saved = 'تم الحفظ';
  static const unexpectedError = 'حدث خطأ غير متوقع';

  // First-run setup
  static const setupTitle = 'إعداد البرنامج لأول مرة';
  static const setupIntro =
      'أدخل بيانات المحل وأنشئ حساب المدير. يمكنك تعديل بيانات المحل لاحقاً من الإعدادات.';
  static const companySection = 'بيانات المحل';
  static const companyName = 'اسم المحل';
  static const companyAddress = 'العنوان';
  static const companyPhone = 'التليفون';
  static const adminSection = 'حساب المدير';
  static const fullName = 'الاسم بالكامل';
  static const username = 'اسم المستخدم';
  static const password = 'كلمة المرور';
  static const confirmPassword = 'تأكيد كلمة المرور';
  static const passwordsDontMatch = 'كلمتا المرور غير متطابقتين';
  static const finishSetup = 'إنهاء الإعداد والدخول';

  // Login
  static const loginTitle = 'تسجيل الدخول';
  static const login = 'دخول';
  static const logout = 'تسجيل الخروج';
  static const roleAdmin = 'مدير';
  static const roleCashier = 'كاشير';

  // Settings: backup
  static const backupSection = 'النسخ الاحتياطي';
  static const backupNow = 'نسخة احتياطية الآن';
  static const backupDone = 'تم إنشاء النسخة الاحتياطية';
  static const backupInfo =
      'يتم حفظ نسخة تلقائياً عند إغلاق البرنامج، ويُحتفظ بآخر 10 نسخ. '
      'البيانات موجودة على هذا الجهاز فقط؛ احتفظ بنسخة على فلاشة أو مجلد سحابي.';
  static const externalFolder = 'مجلد خارجي (فلاشة أو مجلد سحابي)';
  static const externalFolderNone = 'لم يتم اختيار مجلد';
  static const chooseFolder = 'اختيار مجلد';
  static const removeFolder = 'إزالة';
  static const noBackups = 'لا توجد نسخ احتياطية بعد';
  static const restore = 'استعادة';
  static const restoreFromFile = 'استعادة من ملف...';
  static const restoreConfirmTitle = 'استعادة نسخة احتياطية؟';
  static const restoreConfirmBody =
      'سيتم استبدال كل البيانات الحالية ببيانات هذه النسخة. '
      'سيتم حفظ نسخة من البيانات الحالية أولاً، ثم يُعاد تشغيل البرنامج.';
  static const restartNow = 'إعادة التشغيل الآن';
  static const restoreReady = 'النسخة جاهزة. سيُعاد تشغيل البرنامج لإتمام الاستعادة.';

  static const backupReasonManual = 'يدوي';
  static const backupReasonAuto = 'عند الإغلاق';
  static const backupReasonMigration = 'قبل التحديث';
  static const backupReasonRestore = 'قبل الاستعادة';

  // Startup problems
  static const startupErrorTitle = 'تعذّر فتح قاعدة البيانات';
  static const startupDamaged =
      'ملف البيانات به مشكلة. استعد آخر نسخة احتياطية سليمة، ثم تواصل مع المطور إذا تكررت المشكلة.';
  static const startupFailed = 'لم يتمكن البرنامج من فتح ملف البيانات:';
}
