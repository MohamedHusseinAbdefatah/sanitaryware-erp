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
  static const ok = 'حسناً';
  static const yes = 'نعم';
  static const no = 'لا';
  static const add = 'إضافة';
  static const edit = 'تعديل';
  static const close = 'إغلاق';
  static const back = 'رجوع';
  static const all = 'الكل';
  static const name = 'الاسم';
  static const notes = 'ملاحظات';
  static const date = 'التاريخ';
  static const status = 'الحالة';
  static const reason = 'السبب';
  static const active = 'نشط';
  static const inactive = 'موقوف';
  static const items = 'صنف';
  static const invalidAmount = 'مبلغ غير صحيح';
  static const invalidQty = 'كمية غير صحيحة';
  static const wholeQtyOnly = 'رقم صحيح فقط';
  static const today = 'اليوم';
  static const thisMonth = 'هذا الشهر';
  static const createdBy = 'بواسطة';

  // Products
  static const newProduct = 'صنف جديد';
  static const editProduct = 'تعديل صنف';
  static const lists = 'التصنيفات والوحدات';
  static const searchProducts = 'بحث بالكود أو الاسم';
  static const lowStockOnly = 'تحت حد الطلب فقط';
  static const noProducts = 'لا توجد أصناف';
  static const code = 'الكود';
  static const productName = 'الصنف';
  static const category = 'التصنيف';
  static const categories = 'التصنيفات';
  static const brand = 'الماركة';
  static const brands = 'الماركات';
  static const unit = 'الوحدة';
  static const units = 'الوحدات';
  static const allowsFractions = 'تقبل الكسور';
  static const allowsFractionsHint = 'مثل المتر: يمكن بيع 1.5';
  static const stock = 'الرصيد';
  static const currentStock = 'الرصيد الحالي';
  static const costPrice = 'التكلفة';
  static const priceRetail = 'قطاعي';
  static const priceWholesale = 'جملة';
  static const priceContractor = 'مقاولين';
  static const minStock = 'حد الطلب';
  static const openingStock = 'رصيد أول المدة';
  static const inactiveHint = 'الصنف الموقوف لا يظهر في البيع';
  static const stockAdjust = 'تسوية رصيد';
  static const stockCard = 'كارت الصنف';
  static const increase = 'زيادة';
  static const decrease = 'نقص';
  static const reasonHint = 'السبب (كسر، جرد، ...)';
  static const noMovements = 'لا توجد حركات';
  static const movementType = 'الحركة';
  static const balanceAfter = 'الرصيد بعدها';
  static const mvOpening = 'رصيد أول المدة';
  static const mvPurchase = 'شراء';
  static const mvSale = 'بيع';
  static const mvSaleCancel = 'إلغاء بيع';
  static const mvSaleReturn = 'مرتجع بيع';
  static const mvPurchaseReturn = 'مرتجع شراء';
  static const mvAdjustment = 'تسوية';

  // Customers and suppliers
  static const newCustomer = 'عميل جديد';
  static const editCustomer = 'تعديل عميل';
  static const newSupplier = 'مورد جديد';
  static const editSupplier = 'تعديل مورد';
  static const searchParties = 'بحث بالاسم أو التليفون';
  static const noCustomers = 'لا يوجد عملاء';
  static const noSuppliers = 'لا يوجد موردون';
  static const phone = 'التليفون';
  static const address = 'العنوان';
  static const priceLevel = 'فئة السعر';
  static const creditLimit = 'حد الائتمان';
  static const creditLimitHint = 'حد الائتمان (اتركه فارغاً بلا حد)';
  static const openingBalance = 'رصيد أول المدة';
  static const openingBalanceCustomer = 'رصيد أول المدة (مستحق على العميل)';
  static const openingBalanceSupplier = 'رصيد أول المدة (مستحق للمورد)';

  // Sales
  static const newInvoice = 'فاتورة جديدة';
  static const salesInvoice = 'فاتورة بيع';
  static const invoiceNo = 'رقم الفاتورة';
  static const automatic = 'تلقائي';
  static const customer = 'العميل';
  static const cashCustomer = 'نقدي';
  static const cashSale = 'بيع نقدي';
  static const searchInvoices = 'بحث برقم الفاتورة أو العميل';
  static const noInvoices = 'لا توجد فواتير';
  static const productSearchHint = 'اكتب كود أو اسم الصنف ثم Enter  (F2)';
  static const searchToAddHint = 'ابحث عن صنف بالأعلى لإضافته للفاتورة';
  static const available = 'المتاح';
  static const qty = 'الكمية';
  static const price = 'السعر';
  static const discount = 'الخصم';
  static const lineTotal = 'الإجمالي';
  static const removeLine = 'حذف السطر';
  static const subtotal = 'المجموع';
  static const invoiceDiscount = 'خصم الفاتورة';
  static const total = 'الإجمالي';
  static const paid = 'المدفوع';
  static const paidNow = 'المدفوع الآن';
  static const remaining = 'المتبقي';
  static const methodCash = 'نقدي';
  static const methodBank = 'تحويل بنكي';
  static const notEnoughStock = 'الكمية أكبر من المتاح';
  static const belowCost = 'السعر أقل من التكلفة';
  static const addAtLeastOneItem = 'أضف صنفاً واحداً على الأقل';
  static const invoiceSaved = 'تم حفظ الفاتورة';
  static const discardInvoice = 'هل تريد ترك الفاتورة بدون حفظ؟';
  static const cancelInvoice = 'إلغاء الفاتورة';
  static const invoiceCancelled = 'تم إلغاء الفاتورة';
  static const cancelled = 'ملغاة';
  static const invoiceCount = 'عدد الفواتير';
  static const totalSales = 'إجمالي المبيعات';

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

  // Settings: printing
  static const printingSection = 'الطباعة';
  static const printTestPage = 'طباعة صفحة تجريبية';
  static const printTestInfo =
      'اطبع هذه الصفحة على طابعة المحل للتأكد من ظهور الحروف العربية والجداول والأرقام بشكل صحيح.';

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
