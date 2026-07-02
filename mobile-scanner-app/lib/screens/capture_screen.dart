import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';

import '../services/document_edge.dart';
import '../services/edge_detector_isolate.dart';
import '../widgets/edge_overlay_painter.dart';

/// Dark theme shared with [ScanFlowScreen]'s `_scanTheme` — duplicated here
/// (not exported from that file) so this screen matches its look without
/// reaching into scan_flow_screen's private members.
final ThemeData _captureTheme = ThemeData(
  brightness: Brightness.dark,
  colorScheme: ColorScheme.fromSeed(
    seedColor: const Color(0xFF0F6CBD),
    brightness: Brightness.dark,
  ),
  scaffoldBackgroundColor: const Color(0xFF121212),
  useMaterial3: true,
);

enum _CaptureState { loading, ready, permissionDenied, permissionPermanentlyDenied, error }

/// Own camera capture screen: full-screen preview, shutter button, running
/// page counter for the session. Each shot is auto-cropped via
/// [detectDocumentCorners]/[warpToCorners] (best-effort — a failed crop still
/// keeps the original photo so the flow is never blocked). "Concluir" pops
/// the accumulated page paths back to the caller.
class CaptureScreen extends StatefulWidget {
  const CaptureScreen({super.key, this.singleShot = false});

  /// When true, the screen pops with the single captured page immediately
  /// after the shutter fires instead of waiting for "Concluir" — used for
  /// rescanning one existing page, where extra shots would otherwise be
  /// captured but silently discarded (only the first page is ever consumed
  /// by the caller in that flow).
  final bool singleShot;

  @override
  State<CaptureScreen> createState() => _CaptureScreenState();
}

class _CaptureScreenState extends State<CaptureScreen> with WidgetsBindingObserver {
  CameraController? _controller;
  _CaptureState _state = _CaptureState.loading;
  final List<String> _captured = [];
  bool _capturing = false;

  // --- Live edge-detection overlay ---
  final LiveEdgeDetector _detector = LiveEdgeDetector();
  bool _detectorReady = false;
  bool _streaming = false;
  bool _disposed = false;
  // Bumped on every _setup() so a stale in-flight run (e.g. a duplicate
  // `resumed` event) abandons instead of orphaning its CameraController.
  int _setupGen = 0;
  int _sensorOrientation = 90;
  final ValueNotifier<EdgeOverlayData?> _overlay =
      ValueNotifier<EdgeOverlayData?>(null);
  // Smoothed corners in upright (portrait) image space, ordered TL,TR,BR,BL.
  List<math.Point<double>>? _smoothed;
  int _missCount = 0;
  int _lastRunMs = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _setup();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState appState) {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) return;
    if (appState == AppLifecycleState.inactive) {
      // Drop back to `loading` in the same setState as the dispose+null —
      // otherwise `_state` stays `ready` with a now-disposed `_controller`,
      // and any rebuild triggered while backgrounded (e.g. a permission
      // dialog, orientation change) hits `_controller!` on a null value.
      _streaming = false;
      _smoothed = null;
      _missCount = 0;
      _overlay.value = null;
      controller.dispose(); // also stops the active image stream
      setState(() {
        _controller = null;
        _state = _CaptureState.loading;
      });
    } else if (appState == AppLifecycleState.resumed) {
      _setup();
    }
  }

  Future<void> _setup() async {
    // A stale run (superseded by a newer _setup, e.g. a duplicate `resumed`)
    // must abandon after each await and dispose its own controller, so we never
    // orphan an initialized CameraController with a running image stream.
    final gen = ++_setupGen;
    setState(() => _state = _CaptureState.loading);

    final status = await Permission.camera.request();
    if (!mounted || gen != _setupGen) return;
    if (status.isPermanentlyDenied) {
      setState(() => _state = _CaptureState.permissionPermanentlyDenied);
      return;
    }
    if (!status.isGranted) {
      setState(() => _state = _CaptureState.permissionDenied);
      return;
    }

    try {
      final cameras = await availableCameras();
      if (!mounted || gen != _setupGen) return;
      final back = cameras.firstWhere(
        (c) => c.lensDirection == CameraLensDirection.back,
        orElse: () => cameras.first,
      );
      final controller = CameraController(
        back,
        ResolutionPreset.high,
        enableAudio: false,
        // yuv420 gives a stable plane layout for startImageStream; its Y plane
        // is the luminance we feed straight into edge detection (no colour
        // conversion). Does not affect takePicture (still JPEG).
        imageFormatGroup: ImageFormatGroup.yuv420,
      );
      await controller.initialize();
      if (!mounted || gen != _setupGen) {
        // A newer run superseded us (or we were unmounted): dispose our own
        // controller rather than leaking it.
        await controller.dispose();
        return;
      }
      _sensorOrientation = back.sensorOrientation;
      final previous = _controller;
      setState(() {
        _controller = controller;
        _state = _CaptureState.ready;
      });
      if (previous != null && previous != controller) {
        await previous.dispose(); // also stops any stream it still held
      }
      await _ensureDetector();
      if (gen != _setupGen) return; // don't start a stream for a stale run
      await _startStream();
    } on CameraException {
      if (!mounted || gen != _setupGen) return;
      setState(() => _state = _CaptureState.error);
    }
  }

  /// Spawns the detection isolate once. On failure we degrade to "camera works,
  /// no overlay" rather than blocking capture — the overlay is additive.
  Future<void> _ensureDetector() async {
    if (_detectorReady) return;
    try {
      await _detector.start();
      _detectorReady = true;
    } catch (_) {
      _detectorReady = false;
    }
  }

  Future<void> _startStream() async {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) return;
    if (_streaming || !_detectorReady || controller.value.isStreamingImages) {
      return;
    }
    try {
      await controller.startImageStream(_onFrame);
      _streaming = true;
    } catch (_) {
      _streaming = false;
    }
  }

  Future<void> _stopStream() async {
    final controller = _controller;
    _streaming = false;
    if (controller == null || !controller.value.isStreamingImages) return;
    try {
      await controller.stopImageStream();
    } catch (_) {}
  }

  // --- Per-frame live detection ------------------------------------------

  /// Camera stream callback. Best-effort: extracts the luminance plane and
  /// hands it to the worker, dropping the frame when busy or throttled. Never
  /// throws — a failure here must never stall the preview or the shutter.
  void _onFrame(CameraImage image) {
    if (_disposed || !mounted || !_detectorReady || _detector.busy) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    if (now - _lastRunMs < 66) return; // ~15 fps detection budget
    _lastRunMs = now;

    final Uint8List gray;
    try {
      gray = _extractLuma(image);
    } catch (_) {
      return;
    }
    _detector.detect(gray, image.width, image.height).then(_onDetection);
  }

  /// Copies the Y (luminance) plane into a contiguous width×height buffer,
  /// stripping any row padding (`bytesPerRow > width`, common on CameraX).
  Uint8List _extractLuma(CameraImage image) {
    final plane = image.planes[0];
    final w = image.width;
    final h = image.height;
    final bpr = plane.bytesPerRow;
    final src = plane.bytes;
    if (bpr == w) {
      return Uint8List.fromList(Uint8List.sublistView(src, 0, w * h));
    }
    final out = Uint8List(w * h);
    for (var row = 0; row < h; row++) {
      final srcStart = row * bpr;
      out.setRange(row * w, row * w + w, src, srcStart);
    }
    return out;
  }

  void _onDetection(LiveDetection? det) {
    if (_disposed || !mounted) return;
    if (det == null || !det.detected) {
      _missCount++;
      // Hysteresis: only drop the outline after several empty frames so it
      // doesn't flicker when detection momentarily loses the document.
      if (_missCount > 6 && _smoothed != null) {
        _smoothed = null;
        _overlay.value = null;
      }
      return;
    }
    _missCount = 0;

    final q = _sensorOrientation;
    final w = det.frameWidth;
    final h = det.frameHeight;
    final double pw;
    final double ph;
    if (q == 90 || q == 270) {
      pw = h.toDouble();
      ph = w.toDouble();
    } else {
      pw = w.toDouble();
      ph = h.toDouble();
    }

    final raw = <math.Point<double>>[
      for (var i = 0; i < 4; i++)
        _rotateToPortrait(det.xs[i], det.ys[i], w, h, q),
    ];

    final prev = _smoothed;
    if (prev == null || _maxCornerDelta(raw, prev) > pw * 0.35) {
      // First detection or a big jump (document swapped / reordered): snap
      // instead of sweeping the outline across the screen.
      _smoothed = raw;
    } else {
      const a = 0.3; // EMA weight for the new frame (lower = steadier, more lag)
      _smoothed = [
        for (var i = 0; i < 4; i++)
          math.Point(
            a * raw[i].x + (1 - a) * prev[i].x,
            a * raw[i].y + (1 - a) * prev[i].y,
          ),
      ];
    }

    _overlay.value = EdgeOverlayData(
      corners: [for (final p in _smoothed!) Offset(p.x, p.y)],
      imageWidth: pw,
      imageHeight: ph,
      wellFramed: _isWellFramed(_smoothed!, pw, ph),
    );
  }

  /// Rotates a sensor-space corner to upright (portrait) image space per the
  /// sensor orientation [q] (0/90/180/270). See the plan's orientation table.
  math.Point<double> _rotateToPortrait(double x, double y, int w, int h, int q) {
    switch (q) {
      case 90:
        return math.Point(h - 1 - y, x);
      case 180:
        return math.Point(w - 1 - x, h - 1 - y);
      case 270:
        return math.Point(y, w - 1 - x);
      default:
        return math.Point(x, y);
    }
  }

  double _maxCornerDelta(
      List<math.Point<double>> a, List<math.Point<double>> b) {
    var maxD = 0.0;
    for (var i = 0; i < 4; i++) {
      final dx = a[i].x - b[i].x;
      final dy = a[i].y - b[i].y;
      final d = math.sqrt(dx * dx + dy * dy);
      if (d > maxD) maxD = d;
    }
    return maxD;
  }

  /// "Well framed" = the quad fills a good share of the frame — the cue to turn
  /// the outline green. Shoelace area over the portrait frame area.
  bool _isWellFramed(List<math.Point<double>> pts, double pw, double ph) {
    var area = 0.0;
    for (var i = 0; i < 4; i++) {
      final j = (i + 1) % 4;
      area += pts[i].x * pts[j].y - pts[j].x * pts[i].y;
    }
    area = area.abs() / 2;
    return area >= pw * ph * 0.45;
  }

  @override
  void dispose() {
    _disposed = true;
    WidgetsBinding.instance.removeObserver(this);
    _streaming = false;
    _controller?.dispose(); // also stops any active image stream
    _detector.dispose();
    _overlay.dispose();
    super.dispose();
  }

  Future<void> _capture() async {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized || _capturing) return;
    setState(() => _capturing = true);
    // Clear any stale outline while the shot is taken.
    _smoothed = null;
    _overlay.value = null;
    try {
      // Most devices can't takePicture() while an image stream is active.
      await _stopStream();
      final file = await controller.takePicture();
      var path = file.path;
      try {
        final corners = await detectDocumentCorners(path);
        path = await warpToCorners(path, corners.points);
      } catch (_) {
        // Auto-crop is best-effort; keep the raw shot if detection/warp fails.
      }
      if (!mounted) return;
      setState(() => _captured.add(path));
      if (widget.singleShot) {
        _finish();
        return;
      }
    } on CameraException {
      // Swallow: keep the session going, user can just try the shot again.
    } finally {
      if (mounted && !_disposed) {
        setState(() => _capturing = false);
        await _startStream();
      }
    }
  }

  void _finish() => Navigator.of(context).pop(_captured);

  @override
  Widget build(BuildContext context) {
    return Theme(
      data: _captureTheme,
      child: Scaffold(
        body: switch (_state) {
          _CaptureState.loading => const Center(child: CircularProgressIndicator()),
          _CaptureState.permissionDenied => _PermissionErrorView(
              message: 'Precisamos da câmera para escanear documentos.',
              buttonLabel: 'Permitir acesso',
              onPressed: _setup,
            ),
          _CaptureState.permissionPermanentlyDenied => _PermissionErrorView(
              message:
                  'O acesso à câmera foi negado permanentemente. Habilite nas configurações do app.',
              buttonLabel: 'Abrir configurações',
              onPressed: openAppSettings,
            ),
          _CaptureState.error => _PermissionErrorView(
              message: 'Não foi possível iniciar a câmera.',
              buttonLabel: 'Tentar novamente',
              onPressed: _setup,
            ),
          _CaptureState.ready => _CameraReadyView(
              controller: _controller!,
              overlay: _overlay,
              pageCount: _captured.length,
              capturing: _capturing,
              onCapture: _capture,
              onFinish: _captured.isEmpty ? null : _finish,
            ),
        },
      ),
    );
  }
}

class _CameraReadyView extends StatelessWidget {
  const _CameraReadyView({
    required this.controller,
    required this.overlay,
    required this.pageCount,
    required this.capturing,
    required this.onCapture,
    required this.onFinish,
  });

  final CameraController controller;
  final ValueListenable<EdgeOverlayData?> overlay;
  final int pageCount;
  final bool capturing;
  final VoidCallback onCapture;
  final VoidCallback? onFinish;

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        // Preview and overlay share ONE AspectRatio box so the outline lands on
        // the document. controller.value.aspectRatio is landscape (w/h > 1); we
        // invert it for the portrait box the preview is displayed in.
        Center(
          child: AspectRatio(
            aspectRatio: 1 / controller.value.aspectRatio,
            child: Stack(
              fit: StackFit.expand,
              children: [
                CameraPreview(controller),
                ValueListenableBuilder<EdgeOverlayData?>(
                  valueListenable: overlay,
                  builder: (_, data, __) => CustomPaint(
                    painter: EdgeOverlayPainter(data),
                  ),
                ),
              ],
            ),
          ),
        ),
        Positioned(
          top: MediaQuery.of(context).padding.top + 12,
          left: 12,
          child: _CircleIconButton(
            icon: Icons.close,
            onPressed: () => Navigator.of(context).pop(<String>[]),
          ),
        ),
        Positioned(
          top: MediaQuery.of(context).padding.top + 12,
          right: 12,
          child: _PageCountBadge(count: pageCount),
        ),
        Positioned(
          left: 0,
          right: 0,
          bottom: MediaQuery.of(context).padding.bottom + 24,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Expanded(
                child: Align(
                  alignment: Alignment.center,
                  child: _ShutterButton(loading: capturing, onPressed: onCapture),
                ),
              ),
            ],
          ),
        ),
        if (onFinish != null)
          Positioned(
            right: 16,
            bottom: MediaQuery.of(context).padding.bottom + 32,
            child: FilledButton(
              onPressed: onFinish,
              style: FilledButton.styleFrom(
                backgroundColor: const Color(0xFF2E7D32),
              ),
              child: const Text('Concluir'),
            ),
          ),
      ],
    );
  }
}

class _ShutterButton extends StatelessWidget {
  const _ShutterButton({required this.loading, required this.onPressed});

  final bool loading;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      shape: const CircleBorder(),
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: loading ? null : onPressed,
        child: Container(
          width: 76,
          height: 76,
          padding: const EdgeInsets.all(4),
          decoration: const BoxDecoration(shape: BoxShape.circle, color: Colors.white),
          child: loading
              ? const Padding(
                  padding: EdgeInsets.all(18),
                  child: CircularProgressIndicator(strokeWidth: 3, color: Colors.black54),
                )
              : Container(
                  decoration: const BoxDecoration(shape: BoxShape.circle, color: Colors.white),
                ),
        ),
      ),
    );
  }
}

class _PageCountBadge extends StatelessWidget {
  const _PageCountBadge({required this.count});

  final int count;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.black54,
      borderRadius: BorderRadius.circular(16),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        child: Text(
          '$count página${count == 1 ? '' : 's'}',
          style: const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w600),
        ),
      ),
    );
  }
}

class _CircleIconButton extends StatelessWidget {
  const _CircleIconButton({required this.icon, required this.onPressed});

  final IconData icon;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.black54,
      shape: const CircleBorder(),
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onPressed,
        child: SizedBox(
          width: 44,
          height: 44,
          child: Icon(icon, color: Colors.white, size: 22),
        ),
      ),
    );
  }
}

class _PermissionErrorView extends StatelessWidget {
  const _PermissionErrorView({
    required this.message,
    required this.buttonLabel,
    required this.onPressed,
  });

  final String message;
  final String buttonLabel;
  final FutureOr<void> Function() onPressed;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.no_photography_outlined, size: 64, color: Colors.white54),
            const SizedBox(height: 16),
            Text(
              message,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white70, fontSize: 15),
            ),
            const SizedBox(height: 24),
            FilledButton(
              onPressed: () => onPressed(),
              child: Text(buttonLabel),
            ),
            const SizedBox(height: 12),
            TextButton(
              onPressed: () => Navigator.of(context).pop(<String>[]),
              child: const Text('Cancelar', style: TextStyle(color: Colors.white70)),
            ),
          ],
        ),
      ),
    );
  }
}
