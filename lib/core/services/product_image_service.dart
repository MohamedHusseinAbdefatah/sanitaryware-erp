import 'package:drift/drift.dart';
import 'package:image/image.dart' as img;

import '../auth/auth_service.dart';
import '../db/database.dart';
import 'audit_service.dart';
import 'errors.dart';

/// The longest side of a stored photo and of its list thumbnail, in pixels.
const productImageSize = 800;
const productThumbSize = 96;

/// One photo per product, kept inside the database (so backups and restores
/// carry it), shrunk to a small JPEG with a thumbnail for lists. Admin only.
class ProductImageService {
  ProductImageService(this.db);

  final AppDatabase db;

  /// Reads any common picture (JPEG, PNG, WebP, BMP, GIF), shrinks it and
  /// stores it as the product's photo, replacing the old one.
  Future<void> setImage(int productId, Uint8List raw, {required User user}) async {
    if (!user.isAdmin) throw ValidationException('صور الأصناف للمدير فقط');
    final product = await (db.select(db.products)..where((t) => t.id.equals(productId))).getSingleOrNull();
    if (product == null) throw ValidationException('الصنف غير موجود');
    final (full, thumb, w, h) = shrink(raw);
    await db.into(db.productImages).insertOnConflictUpdate(ProductImagesCompanion.insert(
          productId: Value(productId),
          bytes: full,
          thumb: thumb,
          width: w,
          height: h,
          updatedAt: Value(DateTime.now()),
        ));
    await AuditService(db).log(
        action: AuditAction.update, entity: 'product', entityId: productId, userId: user.id, details: 'صورة الصنف');
  }

  /// The picture as a JPEG no bigger than [productImageSize], its thumbnail,
  /// and its size. Throws when the file is not a picture.
  static (Uint8List, Uint8List, int, int) shrink(Uint8List raw) {
    img.Image? decoded;
    try {
      decoded = img.decodeImage(raw);
    } on Object {
      decoded = null;
    }
    if (decoded == null) throw ValidationException('الملف ليس صورة يمكن قراءتها (JPG أو PNG)');
    final oriented = img.bakeOrientation(decoded);
    img.Image fit(int max) => oriented.width >= oriented.height
        ? (oriented.width > max ? img.copyResize(oriented, width: max) : oriented)
        : (oriented.height > max ? img.copyResize(oriented, height: max) : oriented);
    final full = fit(productImageSize);
    final small = fit(productThumbSize);
    return (
      Uint8List.fromList(img.encodeJpg(full, quality: 82)),
      Uint8List.fromList(img.encodeJpg(small, quality: 75)),
      full.width,
      full.height,
    );
  }

  Future<void> remove(int productId, {required User user}) async {
    if (!user.isAdmin) throw ValidationException('صور الأصناف للمدير فقط');
    await (db.delete(db.productImages)..where((t) => t.productId.equals(productId))).go();
    await AuditService(db).log(
        action: AuditAction.update, entity: 'product', entityId: productId, userId: user.id, details: 'حذف صورة الصنف');
  }

  /// The full photo, or null.
  Future<Uint8List?> image(int productId) async =>
      (await (db.select(db.productImages)..where((t) => t.productId.equals(productId))).getSingleOrNull())?.bytes;

  /// The products that have a photo, with their thumbnails; updates on change.
  Stream<Map<int, Uint8List>> watchThumbs() {
    final q = db.selectOnly(db.productImages)..addColumns([db.productImages.productId, db.productImages.thumb]);
    return q.watch().map((rows) => {
          for (final r in rows) r.read(db.productImages.productId)!: r.read(db.productImages.thumb)!,
        });
  }
}
