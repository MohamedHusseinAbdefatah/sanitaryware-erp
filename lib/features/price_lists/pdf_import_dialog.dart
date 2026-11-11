part of 'price_lists_screen.dart';

/// Where the PDF a version was read from is kept, next to the database.
File _sourcePdf(File databaseFile, int listId) =>
    File('${databaseFile.parent.path}${Platform.pathSeparator}price_list_sources'
        '${Platform.pathSeparator}PL-$listId.pdf');

/// "5-40, 45" -> {5..40, 45}; empty -> null (all pages). Throws on bad text.
Set<int>? _parsePages(String text, int pageCount) {
  final t = text.trim();
  if (t.isEmpty) return null;
  final out = <int>{};
  for (final part in t.split(RegExp(r'[,،\s]+')).where((s) => s.isNotEmpty)) {
    final m = RegExp(r'^(\d+)(?:-(\d+))?$').firstMatch(part);
    if (m == null) throw ValidationException('الصفحات "$part" غير مفهومة. اكتبها هكذا: 5-40، 45');
    final a = int.parse(m.group(1)!);
    final b = int.parse(m.group(2) ?? m.group(1)!);
    if (a < 1 || b < a || b > pageCount) {
      throw ValidationException('الصفحات "$part" خارج الملف (عدد صفحاته $pageCount)');
    }
    for (var i = a; i <= b; i++) {
      out.add(i);
    }
  }
  return out;
}

/// Import a supplier's PDF price list into a new version. The text is read
/// from the file (never from a picture), the person names the price columns,
/// and the rows go through the same matching and review as an Excel file.
class _PdfImportDialog extends ConsumerStatefulWidget {
  const _PdfImportDialog();

  @override
  ConsumerState<_PdfImportDialog> createState() => _PdfImportDialogState();
}

class _PdfImportDialogState extends ConsumerState<_PdfImportDialog> {
  final _name = TextEditingController();
  final _type = TextEditingController();
  final _pages = TextEditingController();
  final _rate = TextEditingController();
  int? _brandId;
  DateTime _from = DateTime.now();
  DateTime? _to;
  String _vat = VatStatus.unverified;
  String? _path;
  String? _fileName;
  int _pageCount = 0;
  String? _pagesRead;

  PdfPriceTable? _table;
  final _include = <String>{};
  final _rename = <String, TextEditingController>{};
  PriceImportPreview? _preview;
  Timer? _debounce;
  bool _busy = false;

  @override
  void dispose() {
    _debounce?.cancel();
    for (final c in [_name, _type, _pages, _rate, ..._rename.values]) {
      c.dispose();
    }
    super.dispose();
  }

  void _clearTable() {
    for (final c in _rename.values) {
      c.dispose();
    }
    _rename.clear();
    _include.clear();
    _table = null;
    _preview = null;
  }

  Future<void> _pick() async {
    final picked = await FilePicker.pickFiles(type: FileType.custom, allowedExtensions: ['pdf']);
    final path = picked?.files.single.path;
    if (path == null || !mounted) return;
    final count = await runGuarded(context, () async {
      try {
        return await const PdfTextReader().pageCount(File(path));
      } on Object {
        throw ValidationException('تعذر فتح الملف كملف PDF. قد يكون تالفاً أو محمياً بكلمة مرور.');
      }
    });
    if (count == null || !mounted) return;
    setState(() {
      _clearTable();
      _path = path;
      _fileName = picked!.files.single.name;
      _pageCount = count;
    });
  }

  Future<void> _read() async {
    if (_brandId == null) {
      await showMessage(context, 'اختر الماركة أولاً: الأكواد تُطابق داخل الماركة');
      return;
    }
    setState(() => _busy = true);
    final table = await runGuarded(context, () async {
      final pages = _parsePages(_pages.text, _pageCount);
      final lines = await const PdfTextReader().read(File(_path!), pages: pages);
      return extractPriceTable(lines);
    });
    if (!mounted) return;
    setState(() => _busy = false);
    if (table == null) return;
    if (table.allScanned) {
      await showMessage(
        context,
        'هذه الصفحات صور ممسوحة ضوئياً وليس فيها نص يمكن قراءته، فلا يمكن استيراد أسعارها بأمان.\n'
        'أدخل الأسعار يدوياً من "إدخال صنف أو مجموعة أصناف"، أو اطلب من المورد ملف Excel '
        'أو PDF نصياً، ثم استورده.',
      );
      return;
    }
    if (table.rows.isEmpty) {
      await showMessage(
        context,
        'لم يُعثر على جدول أسعار في هذه الصفحات: لا توجد صفوف فيها كود وسعر.\n'
        'تأكد من الصفحات المختارة، أو حوّل القائمة إلى Excel على النموذج.',
      );
      return;
    }
    setState(() {
      _clearTable();
      _table = table;
      _pagesRead = _pages.text.trim();
      for (final c in table.columns) {
        // Columns found only by position have no name; the person names them.
        final automatic = c.unnamed || c.label.startsWith(numberedPrefix);
        _rename[c.label] = TextEditingController(text: automatic ? '' : c.label);
        if (!c.unnamed) _include.add(c.label);
      }
    });
    await _refresh();
  }

  Future<void> _refresh() async {
    final table = _table;
    if (table == null || _brandId == null) return;
    final preview = await runGuarded(
      context,
      () => ref.read(priceListImportServiceProvider).previewPdf(
            table,
            brandId: _brandId!,
            include: {..._include},
            rename: {for (final e in _rename.entries) e.key: e.value.text.trim().isEmpty ? e.key : e.value.text.trim()},
          ),
    );
    if (preview != null && mounted) setState(() => _preview = preview);
  }

  void _refreshSoon() {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 400), _refresh);
  }

  Future<void> _pickDate(bool from) async {
    final d = await showDatePicker(
      context: context,
      initialDate: (from ? _from : _to) ?? _from,
      firstDate: DateTime(2020),
      lastDate: DateTime(2100),
    );
    if (d != null) setState(() => from ? _from = d : _to = d);
  }

  /// Why the chosen columns cannot be saved yet, or null.
  String? get _columnProblem {
    if (_table == null) return null;
    if (_include.isEmpty) return 'اختر عمود سعر واحداً على الأقل';
    if (_include.length == 1) return null;
    final names = <String>[];
    for (final l in _include) {
      final n = _rename[l]!.text.trim();
      if (n.isEmpty) return 'سمِّ كل عمود مختار باللون الذي يخصه (مثال: أبيض، برجامون)';
      names.add(n);
    }
    if (names.toSet().length != names.length) return 'عمودان مختاران لهما نفس الاسم';
    return null;
  }

  bool get _ready =>
      _brandId != null &&
      _name.text.trim().isNotEmpty &&
      _type.text.trim().isNotEmpty &&
      _columnProblem == null &&
      (_preview?.canImport ?? false) &&
      // The pages that were read are the pages that are saved.
      _pages.text.trim() == (_pagesRead ?? '') &&
      !_busy;

  Future<void> _save() async {
    setState(() => _busy = true);
    // Check once more with exactly what is on screen.
    _debounce?.cancel();
    await _refresh();
    if (!mounted) return;
    final dbFile = ref.read(databaseFileProvider);
    final result = await runGuarded(
      context,
      () => ref.read(priceListImportServiceProvider).import(
            _preview!,
            header: PriceListHeader(
              name: _name.text,
              brandId: _brandId!,
              listType: _type.text,
              effectiveFrom: _from,
              effectiveTo: _to,
              vatStatus: _vat,
              vatRateBp: _rate.text.trim().isEmpty ? null : _bp(_rate.text),
              sourceFile: _fileName,
              sourcePages: _pagesRead == null || _pagesRead!.isEmpty ? null : _pagesRead,
            ),
            user: ref.read(currentUserProvider)!,
          ),
    );
    if (!mounted) return;
    setState(() => _busy = false);
    if (result == null) return;
    var kept = true;
    try {
      final target = _sourcePdf(dbFile, result.id);
      await target.parent.create(recursive: true);
      await File(_path!).copy(target.path);
    } on Object catch (e, stack) {
      kept = false;
      ErrorLog.record(e, stack, where: 'keeping the source PDF');
    }
    if (!mounted) return;
    showToast(
      context,
      'PL-${result.id}: أسعار لأصناف معروفة ${result.matched}، أصناف جديدة ${result.created}، '
      'قيد المراجعة ${result.review}${kept ? '' : ' (تعذر حفظ نسخة من ملف PDF)'}',
    );
    Navigator.pop(context);
  }

  Widget _columnTile(PdfPriceColumn c) {
    final samples = _table!.rows
        .where((r) => r.prices.containsKey(c.label))
        .take(3)
        .map((r) => '${r.code}: ${r.prices[c.label]}')
        .join(' · ');
    final included = _include.contains(c.label);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Checkbox(
            value: included,
            onChanged: (v) {
              setState(() => v == true ? _include.add(c.label) : _include.remove(c.label));
              _refresh();
            },
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('${c.label} — ${c.count} سعر', style: const TextStyle(fontWeight: FontWeight.bold)),
                Text(samples, style: Theme.of(context).textTheme.bodySmall, textDirection: TextDirection.ltr),
              ],
            ),
          ),
          const SizedBox(width: 8),
          SizedBox(
            width: 150,
            child: TextField(
              controller: _rename[c.label],
              enabled: included,
              decoration: const InputDecoration(labelText: 'اللون / الاسم', isDense: true),
              onChanged: (_) {
                setState(() {});
                _refreshSoon();
              },
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final brands = ref.watch(_brandsProvider).valueOrNull ?? const <Brand>[];
    final t = _table;
    final p = _preview;
    final stopped = p?.rows.where((r) => !r.ok).take(8).toList() ?? const [];
    final problem = _columnProblem;
    return AlertDialog(
      title: const Text('استيراد قائمة من ملف PDF (إصدار جديد)'),
      content: SizedBox(
        width: 640,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'يُقرأ النص المكتوب في الملف: الأكواد والأسعار والوصف الإنجليزي. لا يُخمَّن أي سعر: '
                'كل صف غير واضح يتوقف للمراجعة مع رقم صفحته. الملفات الممسوحة ضوئياً (صور) لا تُقرأ.',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<int>(
                isExpanded: true,
                initialValue: _brandId,
                decoration: const InputDecoration(labelText: 'الماركة'),
                items: [for (final b in brands) DropdownMenuItem(value: b.id, child: Text(b.name))],
                onChanged: (v) {
                  setState(() => _brandId = v);
                  _refresh();
                },
              ),
              const SizedBox(height: 12),
              ListTypeField(
                brandId: _brandId,
                controller: _type,
                label: 'نوع القائمة (مثال: أطقم اقتصادية، بانيوهات)',
                onChanged: () => setState(() {}),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _name,
                decoration: const InputDecoration(labelText: 'اسم القائمة (مثال: سانيبور نوفمبر 2026)'),
                onChanged: (_) => setState(() {}),
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 12,
                runSpacing: 8,
                children: [
                  OutlinedButton.icon(
                    onPressed: () => _pickDate(true),
                    icon: const Icon(Icons.event),
                    label: Text('سارية من ${_date(_from)}'),
                  ),
                  OutlinedButton.icon(
                    onPressed: () => _pickDate(false),
                    icon: const Icon(Icons.event_busy),
                    label: Text(_to == null ? 'حتى: مفتوحة' : 'حتى ${_date(_to!)}'),
                  ),
                  const Chip(label: Text('العملة: EGP')),
                ],
              ),
              const SizedBox(height: 12),
              _VatFields(status: _vat, rate: _rate, onStatus: (v) => setState(() => _vat = v)),
              const SizedBox(height: 12),
              OutlinedButton.icon(
                onPressed: _busy ? null : _pick,
                icon: const Icon(Icons.picture_as_pdf_outlined),
                label: Text(_fileName == null ? 'اختر ملف PDF' : '$_fileName ($_pageCount صفحة)'),
              ),
              if (_path != null) ...[
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _pages,
                        decoration: const InputDecoration(
                          labelText: 'الصفحات (فارغ = كل الملف، مثال: 5-40، 45)',
                        ),
                        onChanged: (_) => setState(() {}),
                      ),
                    ),
                    const SizedBox(width: 12),
                    FilledButton.tonalIcon(
                      onPressed: _busy ? null : _read,
                      icon: _busy
                          ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                          : const Icon(Icons.manage_search),
                      label: const Text('قراءة الملف'),
                    ),
                  ],
                ),
                if (t != null && _pages.text.trim() != (_pagesRead ?? ''))
                  Text('غيّرت الصفحات: اضغط "قراءة الملف" من جديد', style: TextStyle(color: scheme.error)),
              ],
              if (t != null) ...[
                const SizedBox(height: 12),
                Text('قُرئت ${t.pagesRead.length} صفحة، ووُجد ${t.rows.length} صف.',
                    style: const TextStyle(fontWeight: FontWeight.bold)),
                if (t.scannedPages.isNotEmpty)
                  Text(
                    'صفحات صور لم تُقرأ (أدخلها يدوياً): ${t.scannedPages.join('، ')}',
                    style: TextStyle(color: scheme.error),
                  ),
                const SizedBox(height: 8),
                const Text('أعمدة الأسعار: اختر الأعمدة التي تريدها وسمِّ كل عمود باللون الذي يخصه.'),
                for (final c in t.columns) _columnTile(c),
                if (problem != null) Text(problem, style: TextStyle(color: scheme.error)),
              ],
              if (p != null && problem == null) ...[
                const SizedBox(height: 12),
                Text('أصناف معروفة يضاف سعرها: ${p.knownCount}', style: const TextStyle(fontWeight: FontWeight.bold)),
                Text('أصناف جديدة تأخذ رقم صنف جديد: ${p.createCount}', style: const TextStyle(fontWeight: FontWeight.bold)),
                if (p.reviewCount > 0)
                  Text('صفوف متوقفة للمراجعة: ${p.reviewCount}', style: TextStyle(color: scheme.error)),
                for (final r in stopped)
                  Text('صفحة ${r.page} · ${r.code}: ${r.reviewReason}', style: TextStyle(color: scheme.error)),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('إلغاء')),
        FilledButton(onPressed: _ready ? _save : null, child: const Text('حفظ الإصدار')),
      ],
    );
  }
}
