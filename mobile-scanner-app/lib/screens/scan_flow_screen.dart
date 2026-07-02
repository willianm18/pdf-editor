import 'dart:io';
import 'dart:math' show Point;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../services/document_edge.dart';
import '../services/image_enhance.dart';
import '../services/qr_parser.dart';
import '../services/upload_service.dart';
import 'capture_screen.dart';

enum _Stage { scanning, review, uploading, success }

/// Dark, CamScanner-style theme applied to the whole scan flow (the Home and QR
/// screens keep the app's default light theme — this Theme is local to here).
final ThemeData _scanTheme = ThemeData(
  brightness: Brightness.dark,
  colorScheme: ColorScheme.fromSeed(
    seedColor: const Color(0xFF0F6CBD),
    brightness: Brightness.dark,
  ),
  scaffoldBackgroundColor: const Color(0xFF121212),
  useMaterial3: true,
);

/// Green used for the selected-filter border and the confirm action.
const Color _accentGreen = Color(0xFF2E7D32);

/// Drives the document-scan -> review -> upload -> success flow for one session.
class ScanFlowScreen extends StatefulWidget {
  const ScanFlowScreen({super.key, required this.target});

  final ScanTarget target;

  @override
  State<ScanFlowScreen> createState() => _ScanFlowScreenState();
}

class _ScanFlowScreenState extends State<ScanFlowScreen> {
  final UploadService _uploadService = const UploadService();

  _Stage _stage = _Stage.scanning;

  /// Source of truth for the pages. [_filters] is a parallel list holding the
  /// manually-chosen filter for each page (default [EnhanceFilter.original]).
  List<String> _images = <String>[];
  List<EnhanceFilter> _filters = <EnhanceFilter>[];
  String? _error;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _scan());
  }

  Future<void> _scan() async {
    setState(() {
      _stage = _Stage.scanning;
      _error = null;
    });

    // Our own camera screen replaces the ML Kit document scanner — it does
    // capture + auto-crop only, skipping any native review UI (that would
    // duplicate our custom _ReviewView below), so we go straight from camera
    // to our screen. Image paths are uploaded individually (PDF export is
    // left off — the backend assembles pages from the images, mirroring the
    // web flow).
    try {
      final images = await Navigator.of(context).push<List<String>>(
        MaterialPageRoute(builder: (_) => const CaptureScreen()),
      );
      if (!mounted) return;
      if (images == null || images.isEmpty) {
        Navigator.of(context).pop();
        return;
      }
      setState(() {
        _images = images;
        // growable: true is REQUIRED — List.filled defaults to a fixed-length
        // list, and _filters later gets .addAll()/.removeAt() (adding or
        // deleting pages). On a fixed-length list those throw UnsupportedError,
        // which desyncs _filters (shorter) from _images and then blows up as a
        // RangeError when the review screen indexes _filters[_currentIndex].
        _filters = List<EnhanceFilter>.filled(
          images.length,
          EnhanceFilter.original,
          growable: true,
        );
        _stage = _Stage.review;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = 'Falha ao escanear: $e';
        _stage = _Stage.review;
      });
    }
  }

  /// Opens the capture screen and APPENDS the resulting pages to the existing
  /// [_images]/[_filters] (unlike [_scan], which replaces them wholesale).
  /// Used by the "+" button on the page thumbnail strip.
  Future<void> _scanAppend() async {
    try {
      final images = await Navigator.of(context).push<List<String>>(
        MaterialPageRoute(builder: (_) => const CaptureScreen()),
      );
      if (!mounted) return;
      if (images == null || images.isEmpty) return;
      setState(() {
        _images.addAll(images);
        _filters.addAll(List<EnhanceFilter>.filled(images.length, EnhanceFilter.original));
        _error = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = 'Falha ao escanear: $e');
    }
  }

  /// Opens the capture screen for a single page and replaces only
  /// `_images[index]` (keeping its position and current filter selection).
  /// Used by the floating "rescan this page" button.
  Future<String?> _rescanPage(int index) async {
    try {
      final images = await Navigator.of(context).push<List<String>>(
        MaterialPageRoute(builder: (_) => const CaptureScreen(singleShot: true)),
      );
      if (!mounted) return null;
      if (images == null || images.isEmpty) return null;
      setState(() {
        _images[index] = images.first;
        _error = null;
      });
      return images.first;
    } catch (e) {
      if (!mounted) return null;
      setState(() => _error = 'Falha ao escanear: $e');
      return null;
    }
  }

  void _selectFilter(int index, EnhanceFilter filter) {
    setState(() => _filters[index] = filter);
  }

  Future<void> _rotatePage(int index) async {
    final rotated = await rotate90(srcPath: _images[index]);
    if (!mounted) return;
    setState(() => _images[index] = rotated);
  }

  /// Applies a manual perspective crop to `_images[index]` (keeping its
  /// position and current filter selection, same as [_rotatePage]).
  Future<void> _applyCrop(int index, List<Point<double>> corners) async {
    final cropped = await warpToCorners(_images[index], corners);
    if (!mounted) return;
    setState(() => _images[index] = cropped);
  }

  void _deletePage(int index) {
    setState(() {
      _images.removeAt(index);
      _filters.removeAt(index);
    });
  }

  Future<void> _upload() async {
    setState(() {
      _stage = _Stage.uploading;
      _error = null;
    });
    try {
      // Bake the chosen filter into a full-resolution file per page; 'original'
      // pages upload their source path unchanged.
      final paths = <String>[];
      for (var i = 0; i < _images.length; i++) {
        paths.add(await enhanceToFile(srcPath: _images[i], filter: _filters[i]));
      }
      await _uploadService.uploadImages(
        uploadUrl: widget.target.uploadUrl,
        imagePaths: paths,
      );
      if (!mounted) return;
      setState(() => _stage = _Stage.success);
    } on UploadException catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.message;
        _stage = _Stage.review;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = 'Falha ao processar imagens: $e';
        _stage = _Stage.review;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Theme(
      data: _scanTheme,
      child: Scaffold(
        body: switch (_stage) {
          _Stage.scanning => const Center(child: CircularProgressIndicator()),
          _Stage.uploading => const _UploadingView(),
          _Stage.success => _SuccessView(
              onScanAnother: _scan,
              onDone: () =>
                  Navigator.of(context).popUntil((route) => route.isFirst),
            ),
          _Stage.review => _ReviewView(
              images: _images,
              filters: _filters,
              error: _error,
              onUpload: _images.isEmpty ? null : _upload,
              onScanFirst: _scan,
              onScanAppend: _scanAppend,
              onRescanPage: _rescanPage,
              onSelectFilter: _selectFilter,
              onRotatePage: _rotatePage,
              onApplyCrop: _applyCrop,
              onDeletePage: _deletePage,
            ),
        },
      ),
    );
  }
}

/// Which control the pill row is driving: the filter strip, or the
/// crop/rotate tab (handles overlay + "Girar 90°" + "Aplicar").
enum _ControlTab {
  filters,
  crop,
}

class _ReviewView extends StatefulWidget {
  const _ReviewView({
    required this.images,
    required this.filters,
    required this.error,
    required this.onUpload,
    required this.onScanFirst,
    required this.onScanAppend,
    required this.onRescanPage,
    required this.onSelectFilter,
    required this.onRotatePage,
    required this.onDeletePage,
    required this.onApplyCrop,
  });

  final List<String> images;
  final List<EnhanceFilter> filters;
  final String? error;
  final VoidCallback? onUpload;
  final VoidCallback onScanFirst;
  final Future<void> Function() onScanAppend;
  final Future<String?> Function(int index) onRescanPage;
  final void Function(int index, EnhanceFilter filter) onSelectFilter;
  final Future<void> Function(int index) onRotatePage;
  final void Function(int index) onDeletePage;
  final Future<void> Function(int index, List<Point<double>> corners) onApplyCrop;

  @override
  State<_ReviewView> createState() => _ReviewViewState();
}

class _ReviewViewState extends State<_ReviewView> {
  late final PageController _pageController;
  int _currentIndex = 0;
  final Map<int, TransformationController> _transformControllers = {};
  _ControlTab _activeTab = _ControlTab.filters;
  bool _rescanningPage = false;
  bool _scanningNewPage = false;
  bool _applyingCrop = false;

  @override
  void initState() {
    super.initState();
    _pageController = PageController();
  }

  @override
  void didUpdateWidget(_ReviewView oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Pages can be deleted from under us; keep _currentIndex in range.
    if (widget.images.length != oldWidget.images.length &&
        widget.images.isNotEmpty &&
        _currentIndex >= widget.images.length) {
      _currentIndex = widget.images.length - 1;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _pageController.hasClients) {
          _pageController.jumpToPage(_currentIndex);
        }
      });
    }
  }

  @override
  void dispose() {
    _pageController.dispose();
    for (final c in _transformControllers.values) {
      c.dispose();
    }
    super.dispose();
  }

  TransformationController _controllerFor(int index) =>
      _transformControllers.putIfAbsent(index, TransformationController.new);

  Future<void> _rescanCurrentPage() async {
    setState(() => _rescanningPage = true);
    try {
      await widget.onRescanPage(_currentIndex);
    } finally {
      if (mounted) setState(() => _rescanningPage = false);
    }
  }

  Future<void> _scanAppendPage() async {
    setState(() => _scanningNewPage = true);
    try {
      await widget.onScanAppend();
    } finally {
      if (mounted) setState(() => _scanningNewPage = false);
    }
  }

  Future<void> _applyCrop(int index, List<Point<double>> corners) async {
    setState(() => _applyingCrop = true);
    try {
      await widget.onApplyCrop(index, corners);
      if (mounted) setState(() => _activeTab = _ControlTab.filters);
    } finally {
      if (mounted) setState(() => _applyingCrop = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (widget.images.isEmpty) {
      return Column(
        children: [
          if (widget.error != null) _ErrorBanner(message: widget.error!),
          const Expanded(
            child: Center(child: Text('Nenhuma página escaneada.')),
          ),
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: _ActionBarButton(
                icon: Icons.document_scanner_outlined,
                label: 'Escanear',
                onPressed: widget.onScanFirst,
              ),
            ),
          ),
        ],
      );
    }

    final total = widget.images.length;
    final cropping = _activeTab == _ControlTab.crop;
    return Column(
      children: [
        if (widget.error != null) _ErrorBanner(message: widget.error!),
        Expanded(
          child: Stack(
            children: [
              PageView.builder(
                controller: _pageController,
                itemCount: total,
                physics: cropping ? const NeverScrollableScrollPhysics() : null,
                onPageChanged: (i) {
                  setState(() => _currentIndex = i);
                  _controllerFor(i).value = Matrix4.identity();
                },
                itemBuilder: (context, i) => cropping && i == _currentIndex
                    ? _CropTab(
                        key: ValueKey('crop:${widget.images[i]}'),
                        path: widget.images[i],
                        applying: _applyingCrop,
                        onRotate: () => widget.onRotatePage(i),
                        onApply: (corners) => _applyCrop(i, corners),
                      )
                    : _FilteredPage(
                        key: ValueKey('${widget.images[i]}:${widget.filters[i].index}'),
                        path: widget.images[i],
                        filter: widget.filters[i],
                        transformationController: _controllerFor(i),
                      ),
              ),
              if (!cropping) const _FloatingBackButton(),
              if (!cropping)
                _FloatingPreviewActions(
                  rescanLoading: _rescanningPage,
                  onRescan: _rescanCurrentPage,
                  onDelete: () => _confirmDelete(context, _currentIndex),
                ),
            ],
          ),
        ),
        _ControlPillsRow(
          activeTab: _activeTab,
          onSelectFilters: () => setState(() => _activeTab = _ControlTab.filters),
          onSelectCrop: () => setState(() => _activeTab = _ControlTab.crop),
        ),
        if (_activeTab == _ControlTab.filters)
          _FilterStrip(
            path: widget.images[_currentIndex],
            selected: widget.filters[_currentIndex],
            onSelect: (f) => widget.onSelectFilter(_currentIndex, f),
          ),
        _PageThumbnailStrip(
          images: widget.images,
          currentIndex: _currentIndex,
          scanningNewPage: _scanningNewPage,
          onSelect: (i) => _pageController.animateToPage(
            i,
            duration: const Duration(milliseconds: 250),
            curve: Curves.easeInOut,
          ),
          onAddPage: _scanAppendPage,
        ),
        _PrimaryAdvanceButton(onPressed: widget.onUpload),
      ],
    );
  }

  Future<void> _confirmDelete(BuildContext context, int index) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Excluir página'),
        content: Text('Remover a página ${index + 1}?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Excluir'),
          ),
        ],
      ),
    );
    if (ok == true) widget.onDeletePage(index);
  }
}

/// Circular floating "back" button pinned over the top-left of the preview.
class _FloatingBackButton extends StatelessWidget {
  const _FloatingBackButton();

  @override
  Widget build(BuildContext context) {
    return Positioned(
      top: MediaQuery.of(context).padding.top + 12,
      left: 12,
      child: Material(
        color: Colors.black54,
        shape: const CircleBorder(),
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: () => Navigator.of(context).pop(),
          child: const SizedBox(
            width: 44,
            height: 44,
            child: Icon(Icons.arrow_back, color: Colors.white, size: 22),
          ),
        ),
      ),
    );
  }
}

/// Floating "rescan this page" / "delete this page" buttons pinned over the
/// bottom-right of the preview.
class _FloatingPreviewActions extends StatelessWidget {
  const _FloatingPreviewActions({
    required this.rescanLoading,
    required this.onRescan,
    required this.onDelete,
  });

  final bool rescanLoading;
  final VoidCallback onRescan;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    return Positioned(
      right: 12,
      bottom: 12,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _FloatingCircleButton(
            icon: Icons.replay,
            loading: rescanLoading,
            onPressed: onRescan,
          ),
          const SizedBox(width: 10),
          _FloatingCircleButton(
            icon: Icons.delete_outline,
            onPressed: onDelete,
          ),
        ],
      ),
    );
  }
}

/// Small round black54 button used for the floating preview actions.
class _FloatingCircleButton extends StatelessWidget {
  const _FloatingCircleButton({
    required this.icon,
    required this.onPressed,
    this.loading = false,
  });

  final IconData icon;
  final VoidCallback? onPressed;
  final bool loading;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.black54,
      shape: const CircleBorder(),
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: loading ? null : onPressed,
        child: SizedBox(
          width: 44,
          height: 44,
          child: Center(
            child: loading
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: Colors.white,
                    ),
                  )
                : Icon(icon, color: Colors.white, size: 22),
          ),
        ),
      ),
    );
  }
}

/// "Filtros" / "Cortar e girar" pill row above the filter strip / crop tab.
class _ControlPillsRow extends StatelessWidget {
  const _ControlPillsRow({
    required this.activeTab,
    required this.onSelectFilters,
    required this.onSelectCrop,
  });

  final _ControlTab activeTab;
  final VoidCallback onSelectFilters;
  final VoidCallback onSelectCrop;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(
        children: [
          _ControlPill(
            icon: Icons.auto_awesome,
            label: 'Filtros',
            selected: activeTab == _ControlTab.filters,
            onTap: onSelectFilters,
          ),
          const SizedBox(width: 10),
          _ControlPill(
            icon: Icons.crop_rotate,
            label: 'Cortar e girar',
            selected: activeTab == _ControlTab.crop,
            onTap: onSelectCrop,
          ),
        ],
      ),
    );
  }
}

/// Single pill in [_ControlPillsRow].
class _ControlPill extends StatelessWidget {
  const _ControlPill({
    required this.icon,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: selected ? Colors.white.withValues(alpha: 0.16) : Colors.white10,
      borderRadius: BorderRadius.circular(20),
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                icon,
                size: 18,
                color: selected
                    ? Theme.of(context).colorScheme.primary
                    : Colors.white70,
              ),
              const SizedBox(width: 6),
              Text(
                label,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: selected ? FontWeight.w600 : FontWeight.normal,
                  color: selected ? Colors.white : Colors.white70,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Horizontal strip of page thumbnails + trailing "add page" tile.
class _PageThumbnailStrip extends StatelessWidget {
  const _PageThumbnailStrip({
    required this.images,
    required this.currentIndex,
    required this.scanningNewPage,
    required this.onSelect,
    required this.onAddPage,
  });

  final List<String> images;
  final int currentIndex;
  final bool scanningNewPage;
  final void Function(int index) onSelect;
  final Future<void> Function() onAddPage;

  @override
  Widget build(BuildContext context) {
    final total = images.length;
    return SizedBox(
      height: 96,
      child: ListView.builder(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        itemCount: total + 1,
        itemBuilder: (context, i) {
          if (i == total) {
            return _AddPageThumbnail(
              loading: scanningNewPage,
              onTap: onAddPage,
            );
          }
          return Padding(
            padding: const EdgeInsets.only(right: 10),
            child: _PageThumbnail(
              path: images[i],
              index: i,
              selected: i == currentIndex,
              onTap: () => onSelect(i),
            ),
          );
        },
      ),
    );
  }
}

/// One page thumbnail: image + numbered badge, green border when selected.
class _PageThumbnail extends StatelessWidget {
  const _PageThumbnail({
    required this.path,
    required this.index,
    required this.selected,
    required this.onTap,
  });

  final String path;
  final int index;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Container(
            width: 64,
            height: 80,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(8),
              border: Border.all(
                color: selected ? _accentGreen : Colors.transparent,
                width: 2,
              ),
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(6),
              // cacheWidth keeps the decoded bitmap small — without it each
              // thumbnail decodes the full-resolution scan (several MB) just
              // to show it at 64dp, which adds up fast with many pages.
              child: Image.file(
                File(_toFilePath(path)),
                fit: BoxFit.cover,
                cacheWidth: 128,
              ),
            ),
          ),
          Positioned(
            left: 4,
            bottom: 4,
            child: Container(
              width: 20,
              height: 20,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: Theme.of(context).colorScheme.primary,
              ),
              child: Center(
                child: Text(
                  '${index + 1}',
                  style: const TextStyle(
                    fontSize: 11,
                    color: Colors.white,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Trailing "+" tile in the page thumbnail strip; shows a spinner while a
/// new page is being scanned.
class _AddPageThumbnail extends StatelessWidget {
  const _AddPageThumbnail({required this.loading, required this.onTap});

  final bool loading;
  final Future<void> Function() onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.white10,
      borderRadius: BorderRadius.circular(8),
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: loading ? null : onTap,
        child: Container(
          width: 64,
          height: 80,
          alignment: Alignment.center,
          child: loading
              ? const SizedBox(
                  width: 22,
                  height: 22,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.add, color: Colors.white70, size: 28),
        ),
      ),
    );
  }
}

/// Full-width "Avançar" primary button footer.
class _PrimaryAdvanceButton extends StatelessWidget {
  const _PrimaryAdvanceButton({required this.onPressed});

  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: SizedBox(
          width: double.infinity,
          height: 52,
          child: FilledButton(
            onPressed: onPressed,
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.primary,
              disabledBackgroundColor:
                  Theme.of(context).colorScheme.primary.withValues(alpha: 0.35),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(26),
              ),
            ),
            child: const Text(
              'Avançar',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
            ),
          ),
        ),
      ),
    );
  }
}

String _toFilePath(String pathOrUri) =>
    pathOrUri.startsWith('file://') ? Uri.parse(pathOrUri).toFilePath() : pathOrUri;

/// One page in the [PageView]: shows the selected filter's result (rendered
/// off-thread) inside an [InteractiveViewer], with a spinner while it renders.
class _FilteredPage extends StatefulWidget {
  const _FilteredPage({
    super.key,
    required this.path,
    required this.filter,
    required this.transformationController,
  });

  final String path;
  final EnhanceFilter filter;
  final TransformationController transformationController;

  @override
  State<_FilteredPage> createState() => _FilteredPageState();
}

class _FilteredPageState extends State<_FilteredPage> {
  Future<Uint8List>? _future;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(_FilteredPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.path != widget.path || oldWidget.filter != widget.filter) {
      _load();
    }
  }

  void _load() {
    _future = enhanceToBytes(srcPath: widget.path, filter: widget.filter);
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(12),
      child: FutureBuilder<Uint8List>(
        future: _future,
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snapshot.hasError || snapshot.data == null) {
            return Center(
              child: Text('Falha ao aplicar filtro: ${snapshot.error ?? ''}'),
            );
          }
          return InteractiveViewer(
            transformationController: widget.transformationController,
            minScale: 1,
            maxScale: 4,
            child: Center(
              child: Image.memory(snapshot.data!, fit: BoxFit.contain),
            ),
          );
        },
      ),
    );
  }
}

/// Minimum touch target for a drag handle, per the plan's accessibility bar.
const double _handleTouchSize = 44;

/// "Cortar e girar" tab: the current page's raw (unfiltered) image with four
/// draggable corner handles, seeded from [detectDocumentCorners]. Handles
/// render slightly differently when the seed came from the whole-image
/// fallback rather than a real detection, so the user isn't misled into
/// thinking "no crop" was an intentional suggestion. "Girar 90°" rotates the
/// page directly; "Aplicar" warps to the current handle positions.
class _CropTab extends StatefulWidget {
  const _CropTab({
    super.key,
    required this.path,
    required this.applying,
    required this.onRotate,
    required this.onApply,
  });

  final String path;
  final bool applying;
  final VoidCallback onRotate;
  final void Function(List<Point<double>> corners) onApply;

  @override
  State<_CropTab> createState() => _CropTabState();
}

class _CropTabState extends State<_CropTab> {
  Future<DocumentCorners>? _future;

  @override
  void initState() {
    super.initState();
    _future = detectDocumentCorners(widget.path);
  }

  @override
  void didUpdateWidget(_CropTab oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.path != widget.path) {
      _future = detectDocumentCorners(widget.path);
    }
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<DocumentCorners>(
      future: _future,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const Center(child: CircularProgressIndicator());
        }
        if (snapshot.hasError || snapshot.data == null) {
          return Center(
            child: Text('Falha ao detectar bordas: ${snapshot.error ?? ''}'),
          );
        }
        return _CropEditor(
          path: widget.path,
          seed: snapshot.data!,
          applying: widget.applying,
          onRotate: widget.onRotate,
          onApply: widget.onApply,
        );
      },
    );
  }
}

/// Owns the live (draggable) corner state once detection has produced a
/// seed. Corners are tracked in image-pixel coordinates; the paint/handle
/// layer maps them to widget coordinates using the `BoxFit.contain` rect
/// computed from the decoded image size.
class _CropEditor extends StatefulWidget {
  const _CropEditor({
    required this.path,
    required this.seed,
    required this.applying,
    required this.onRotate,
    required this.onApply,
  });

  final String path;
  final DocumentCorners seed;
  final bool applying;
  final VoidCallback onRotate;
  final void Function(List<Point<double>> corners) onApply;

  @override
  State<_CropEditor> createState() => _CropEditorState();
}

class _CropEditorState extends State<_CropEditor> {
  late List<Point<double>> _corners = widget.seed.points;
  ui.Image? _decoded;

  @override
  void initState() {
    super.initState();
    _decodeImage();
  }

  @override
  void didUpdateWidget(_CropEditor oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.path != widget.path) {
      _corners = widget.seed.points;
      _decoded = null;
      _decodeImage();
    }
  }

  Future<void> _decodeImage() async {
    final bytes = await File(_toFilePath(widget.path)).readAsBytes();
    final codec = await ui.instantiateImageCodec(bytes);
    final frame = await codec.getNextFrame();
    if (!mounted) return;
    setState(() => _decoded = frame.image);
  }

  /// Maps [_decoded]'s pixel rect onto [container] the same way
  /// `BoxFit.contain` would, so handle positions match what `Image.file`
  /// with the same fit renders on screen.
  Rect _imageRectIn(Size container) {
    final image = _decoded!;
    final imageSize = Size(image.width.toDouble(), image.height.toDouble());
    final fitted = applyBoxFit(BoxFit.contain, imageSize, container);
    final destSize = fitted.destination;
    final offset = Offset(
      (container.width - destSize.width) / 2,
      (container.height - destSize.height) / 2,
    );
    return offset & destSize;
  }

  Offset _toWidget(Point<double> corner, Rect imageRect) {
    final image = _decoded!;
    final sx = imageRect.width / image.width;
    final sy = imageRect.height / image.height;
    return Offset(imageRect.left + corner.x * sx, imageRect.top + corner.y * sy);
  }

  Point<double> _toImage(Offset widgetPoint, Rect imageRect) {
    final image = _decoded!;
    final sx = image.width / imageRect.width;
    final sy = image.height / imageRect.height;
    final clampedX = widgetPoint.dx.clamp(imageRect.left, imageRect.right);
    final clampedY = widgetPoint.dy.clamp(imageRect.top, imageRect.bottom);
    return Point(
      (clampedX - imageRect.left) * sx,
      (clampedY - imageRect.top) * sy,
    );
  }

  @override
  Widget build(BuildContext context) {
    final decoded = _decoded;
    return Padding(
      padding: const EdgeInsets.all(12),
      child: Column(
        children: [
          Expanded(
            child: decoded == null
                ? const Center(child: CircularProgressIndicator())
                : LayoutBuilder(
                    builder: (context, constraints) {
                      final container = Size(constraints.maxWidth, constraints.maxHeight);
                      final imageRect = _imageRectIn(container);
                      return Stack(
                        fit: StackFit.expand,
                        children: [
                          Center(
                            child: Image.file(File(_toFilePath(widget.path)), fit: BoxFit.contain),
                          ),
                          CustomPaint(
                            size: container,
                            painter: _CropOutlinePainter(
                              points: [for (final c in _corners) _toWidget(c, imageRect)],
                              detected: widget.seed.detected,
                            ),
                          ),
                          for (var i = 0; i < _corners.length; i++)
                            _CropHandle(
                              key: ValueKey('handle-$i'),
                              position: _toWidget(_corners[i], imageRect),
                              detected: widget.seed.detected,
                              onDragUpdate: (widgetPos) {
                                setState(() {
                                  _corners = [..._corners];
                                  _corners[i] = _toImage(widgetPos, imageRect);
                                });
                              },
                            ),
                        ],
                      );
                    },
                  ),
          ),
          const SizedBox(height: 8),
          if (!widget.seed.detected)
            const Padding(
              padding: EdgeInsets.only(bottom: 8),
              child: Text(
                'Bordas não detectadas automaticamente — ajuste os cantos manualmente.',
                style: TextStyle(color: Colors.white70, fontSize: 12),
                textAlign: TextAlign.center,
              ),
            ),
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: widget.applying ? null : widget.onRotate,
                  icon: const Icon(Icons.rotate_right),
                  label: const Text('Girar 90°'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: FilledButton.icon(
                  onPressed: widget.applying ? null : () => widget.onApply(_corners),
                  style: FilledButton.styleFrom(backgroundColor: _accentGreen),
                  icon: widget.applying
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                        )
                      : const Icon(Icons.check),
                  label: const Text('Aplicar'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Draws the quadrilateral connecting the four handles. Dashed and dimmer
/// when [detected] is false, to signal the corners are the whole-image
/// fallback rather than a real edge detection.
class _CropOutlinePainter extends CustomPainter {
  const _CropOutlinePainter({required this.points, required this.detected});

  final List<Offset> points;
  final bool detected;

  @override
  void paint(Canvas canvas, Size size) {
    if (points.length != 4) return;
    final paint = Paint()
      ..color = detected ? _accentGreen : Colors.white54
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2;
    final path = Path()..addPolygon(points, true);
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(_CropOutlinePainter oldDelegate) =>
      oldDelegate.points != points || oldDelegate.detected != detected;
}

/// One draggable corner handle. Touch target is [_handleTouchSize] square
/// (44dp), with the visible dot centred inside it. Colour signals whether
/// the current position came from real detection (green) or the fallback
/// (neutral white) — same convention as [_CropOutlinePainter].
class _CropHandle extends StatelessWidget {
  const _CropHandle({
    super.key,
    required this.position,
    required this.detected,
    required this.onDragUpdate,
  });

  final Offset position;
  final bool detected;
  final void Function(Offset widgetPosition) onDragUpdate;

  @override
  Widget build(BuildContext context) {
    return Positioned(
      left: position.dx - _handleTouchSize / 2,
      top: position.dy - _handleTouchSize / 2,
      child: GestureDetector(
        onPanUpdate: (details) => onDragUpdate(position + details.delta),
        behavior: HitTestBehavior.opaque,
        child: SizedBox(
          width: _handleTouchSize,
          height: _handleTouchSize,
          child: Center(
            child: Container(
              width: 22,
              height: 22,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: (detected ? _accentGreen : Colors.white).withValues(alpha: 0.85),
                border: Border.all(color: Colors.white, width: 2),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Horizontal strip of filter thumbnails for the current page. Each thumbnail
/// is the current page rendered at width 120 through that filter, cached by
/// "pageIndex:filter" (keyed on the source path so rotation invalidates it).
class _FilterStrip extends StatefulWidget {
  const _FilterStrip({
    required this.path,
    required this.selected,
    required this.onSelect,
  });

  final String path;
  final EnhanceFilter selected;
  final void Function(EnhanceFilter filter) onSelect;

  @override
  State<_FilterStrip> createState() => _FilterStripState();
}

class _FilterStripState extends State<_FilterStrip> {
  static const double _thumbWidth = 92;
  final Map<String, Future<Uint8List>> _cache = {};

  Future<Uint8List> _thumb(EnhanceFilter filter) {
    final key = '${widget.path}:${filter.index}';
    return _cache.putIfAbsent(
      key,
      () => enhanceToBytes(srcPath: widget.path, filter: filter, maxWidth: 120),
    );
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      // 92 (thumb) + 4 (gap) + label line — 118 clipped the label by ~8px on
      // devices with larger default text scale; 128 gives it headroom.
      height: 128,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        itemCount: EnhanceFilter.values.length,
        separatorBuilder: (_, __) => const SizedBox(width: 10),
        itemBuilder: (context, i) {
          final filter = EnhanceFilter.values[i];
          final isSelected = filter == widget.selected;
          return GestureDetector(
            onTap: () => widget.onSelect(filter),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: _thumbWidth,
                  height: _thumbWidth,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(
                      color: isSelected ? _accentGreen : Colors.transparent,
                      width: 3,
                    ),
                  ),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(6),
                    child: FutureBuilder<Uint8List>(
                      future: _thumb(filter),
                      builder: (context, snapshot) {
                        if (snapshot.hasData) {
                          return Image.memory(snapshot.data!, fit: BoxFit.cover);
                        }
                        return Container(
                          color: Colors.white10,
                          child: const Center(
                            child: SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  filter.label,
                  style: TextStyle(
                    fontSize: 11,
                    color: isSelected ? _accentGreen : null,
                    fontWeight: isSelected ? FontWeight.w600 : FontWeight.normal,
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

/// Circular-icon + label action button. [confirm] renders a larger, filled
/// green circle with a white icon (the primary "send" action).
class _ActionBarButton extends StatelessWidget {
  const _ActionBarButton({
    required this.icon,
    required this.label,
    required this.onPressed,
  });

  final IconData icon;
  final String label;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final enabled = onPressed != null;
    const double size = 52;
    const Color circleColor = Colors.white12;
    final Color iconColor = enabled ? Colors.white : Colors.white38;
    return InkWell(
      onTap: onPressed,
      borderRadius: BorderRadius.circular(size),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: size,
              height: size,
              decoration: const BoxDecoration(color: circleColor, shape: BoxShape.circle),
              child: Icon(icon, color: iconColor, size: 26),
            ),
            const SizedBox(height: 6),
            Text(label, style: const TextStyle(fontSize: 12)),
          ],
        ),
      ),
    );
  }
}

class _ErrorBanner extends StatelessWidget {
  const _ErrorBanner({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      color: Theme.of(context).colorScheme.errorContainer,
      padding: const EdgeInsets.all(12),
      child: Text(
        message,
        style: TextStyle(color: Theme.of(context).colorScheme.onErrorContainer),
      ),
    );
  }
}

class _UploadingView extends StatelessWidget {
  const _UploadingView();

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          CircularProgressIndicator(),
          SizedBox(height: 16),
          Text('Enviando...'),
        ],
      ),
    );
  }
}

class _SuccessView extends StatelessWidget {
  const _SuccessView({required this.onScanAnother, required this.onDone});

  final VoidCallback onScanAnother;
  final VoidCallback onDone;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.check_circle, size: 96, color: Colors.green),
            const SizedBox(height: 16),
            Text('Enviado com sucesso!',
                style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 32),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: onScanAnother,
                icon: const Icon(Icons.document_scanner_outlined),
                label: const Text('Escanear outro'),
              ),
            ),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed: onDone,
                child: const Text('Concluir'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
