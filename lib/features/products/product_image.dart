import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/auth/session.dart';
import '../../core/providers.dart';
import '../../core/widgets/feedback.dart';

final _fullImageProvider = FutureProvider.autoDispose.family<Uint8List?, int>(
    (ref, productId) => ref.watch(productImageServiceProvider).image(productId));

/// The product's photo in the product form: choose, replace or remove it.
class ProductImageBox extends ConsumerWidget {
  const ProductImageBox({super.key, required this.productId});

  final int productId;

  Future<void> _pick(BuildContext context, WidgetRef ref) async {
    final picked = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['jpg', 'jpeg', 'png', 'webp', 'bmp', 'gif'],
    );
    final path = picked?.files.single.path;
    if (path == null || !context.mounted) return;
    final ok = await runGuarded(context, () async {
      await ref
          .read(productImageServiceProvider)
          .setImage(productId, await File(path).readAsBytes(), user: ref.read(currentUserProvider)!);
      return true;
    });
    if (ok == true) ref.invalidate(_fullImageProvider(productId));
  }

  Future<void> _remove(BuildContext context, WidgetRef ref) async {
    final ok = await runGuarded(context, () async {
      await ref.read(productImageServiceProvider).remove(productId, user: ref.read(currentUserProvider)!);
      return true;
    });
    if (ok == true) ref.invalidate(_fullImageProvider(productId));
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final bytes = ref.watch(_fullImageProvider(productId)).valueOrNull;
    final scheme = Theme.of(context).colorScheme;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Container(
          width: 140,
          height: 140,
          decoration: BoxDecoration(
            border: Border.all(color: scheme.outlineVariant),
            borderRadius: BorderRadius.circular(8),
            color: scheme.surfaceContainerHighest,
          ),
          clipBehavior: Clip.antiAlias,
          child: bytes == null
              ? Icon(Icons.image_outlined, size: 48, color: scheme.outline)
              : InkWell(
                  onTap: () => showProductImage(context, productId),
                  child: Image.memory(bytes, fit: BoxFit.contain),
                ),
        ),
        const SizedBox(width: 16),
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('صورة الصنف', style: TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 6),
            OutlinedButton.icon(
              onPressed: () => _pick(context, ref),
              icon: const Icon(Icons.add_photo_alternate_outlined),
              label: Text(bytes == null ? 'اختيار صورة' : 'تغيير الصورة'),
            ),
            if (bytes != null) ...[
              const SizedBox(height: 6),
              TextButton.icon(
                onPressed: () => _remove(context, ref),
                icon: const Icon(Icons.delete_outline),
                label: const Text('حذف الصورة'),
              ),
            ],
            const SizedBox(height: 4),
            Text('JPG أو PNG. تُصغر وتُحفظ مع البيانات والنسخ الاحتياطي.',
                style: Theme.of(context).textTheme.bodySmall),
          ],
        ),
      ],
    );
  }
}

/// A small photo for lists; empty when the product has none. A click shows
/// the full photo.
class ProductThumb extends ConsumerWidget {
  const ProductThumb({super.key, required this.productId, this.size = 36, this.zoom = true});

  final int productId;
  final double size;

  /// Tapping opens the full photo (off where the tap means something else).
  final bool zoom;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final thumb = ref.watch(productThumbsProvider).valueOrNull?[productId];
    if (thumb == null) {
      // No photo: an empty frame in lists, a soft placeholder on cards.
      return SizedBox(
        width: size,
        height: size,
        child: size >= 60 ? Icon(Icons.image_outlined, size: size * .45, color: Colors.black26) : null,
      );
    }
    final image = ClipRRect(
      borderRadius: BorderRadius.circular(4),
      child: Image.memory(thumb, width: size, height: size, fit: BoxFit.cover, gaplessPlayback: true),
    );
    if (!zoom) return image;
    return InkWell(
      onTap: () => showProductImage(context, productId),
      borderRadius: BorderRadius.circular(4),
      child: image,
    );
  }
}

/// The full photo in a dialog.
Future<void> showProductImage(BuildContext context, int productId) => showDialog<void>(
      context: context,
      builder: (context) => Consumer(
        builder: (context, ref, _) {
          final bytes = ref.watch(_fullImageProvider(productId)).valueOrNull;
          return Dialog(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: bytes == null
                  ? const SizedBox(width: 200, height: 200, child: Center(child: CircularProgressIndicator()))
                  : InteractiveViewer(child: Image.memory(bytes, fit: BoxFit.contain)),
            ),
          );
        },
      ),
    );
