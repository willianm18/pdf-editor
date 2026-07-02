import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';

import 'document_edge.dart';

/// Result of one live detection, in the ORIGINAL frame's pixel coordinates
/// (the [frameWidth]×[frameHeight] passed to [LiveEdgeDetector.detect]) and in
/// the sensor's own orientation. The caller rotates/scales these into preview
/// space. [xs]/[ys] hold 4 corners ordered TL, TR, BR, BL.
class LiveDetection {
  const LiveDetection({
    required this.xs,
    required this.ys,
    required this.detected,
    required this.frameWidth,
    required this.frameHeight,
  });

  final List<double> xs;
  final List<double> ys;
  final bool detected;
  final int frameWidth;
  final int frameHeight;
}

/// Runs document-edge detection on camera frames in a long-lived worker
/// isolate, with single-frame backpressure.
///
/// Why a persistent isolate (not `Isolate.run` per frame): spawning and tearing
/// down an isolate every frame at ~15fps churns memory and stutters the
/// preview — the exact jitter we're trying to avoid. Here the spawn cost is
/// paid once; each frame only transfers the luminance buffer (zero-copy via
/// [TransferableTypedData]) and gets 8 doubles back.
///
/// Backpressure: while a frame is in flight [busy] is true and [detect] returns
/// null immediately, so callers drop frames instead of queueing them.
class LiveEdgeDetector {
  Isolate? _isolate;
  SendPort? _toWorker;
  ReceivePort? _fromWorker;
  Completer<LiveDetection?>? _pending;
  bool _busy = false;
  // Self-heals a lost/hung worker reply: if a native OpenCV call wedges on a
  // pathological frame, the reply (not even the null-on-catch) never arrives
  // and _busy would stay true forever, freezing the overlay for the whole
  // session. The watchdog releases backpressure so the next frame recovers.
  Timer? _watchdog;
  static const Duration _replyTimeout = Duration(milliseconds: 750);
  static const Duration _handshakeTimeout = Duration(seconds: 5);

  /// True once a detection is in flight; callers should skip extracting the
  /// frame while this is set.
  bool get busy => _busy;

  /// True once the worker isolate has completed its handshake.
  bool get isReady => _toWorker != null;

  /// Spawns the worker and waits for its handshake. Throws if the spawn fails;
  /// callers should degrade to "no overlay" rather than surfacing an error.
  Future<void> start() async {
    if (_toWorker != null) return;
    final fromWorker = ReceivePort();
    _fromWorker = fromWorker;
    final ready = Completer<void>();

    fromWorker.listen((msg) {
      if (msg is SendPort) {
        _toWorker = msg;
        if (!ready.isCompleted) ready.complete();
      } else if (msg is LiveDetection?) {
        _watchdog?.cancel();
        _busy = false;
        final pending = _pending;
        _pending = null;
        pending?.complete(msg);
      }
    });

    try {
      _isolate = await Isolate.spawn(_workerEntry, fromWorker.sendPort);
      // Bound the handshake so a worker that dies before sending its port turns
      // into a caught TimeoutException (→ degrade to "no overlay") instead of
      // hanging _setup() forever.
      await ready.future.timeout(_handshakeTimeout);
    } catch (_) {
      // Clean up the half-started detector so a retry starts fresh and no
      // ReceivePort/isolate leaks. _ensureDetector swallows the rethrow.
      _isolate?.kill(priority: Isolate.immediate);
      fromWorker.close();
      _isolate = null;
      _toWorker = null;
      _fromWorker = null;
      rethrow;
    }
  }

  /// Queues one frame for detection. [gray] is a contiguous row-major CV_8UC1
  /// buffer of size [width]×[height]. Returns null immediately if the worker is
  /// busy or not ready; otherwise resolves with the detection (or null on any
  /// worker-side error — detection is best-effort and never throws here).
  Future<LiveDetection?> detect(Uint8List gray, int width, int height) {
    final toWorker = _toWorker;
    if (toWorker == null || _busy) return Future.value(null);
    _busy = true;
    final completer = Completer<LiveDetection?>();
    _pending = completer;
    _watchdog?.cancel();
    _watchdog = Timer(_replyTimeout, () {
      // Reply never came (wedged native call / lost message): release
      // backpressure so the very next frame proceeds. A late reply for this
      // frame finds _pending null and just harmlessly resets _busy.
      if (identical(_pending, completer)) {
        _busy = false;
        _pending = null;
        if (!completer.isCompleted) completer.complete(null);
      }
    });
    toWorker.send(_FrameRequest(
      TransferableTypedData.fromList([gray]),
      width,
      height,
    ));
    return completer.future;
  }

  /// Kills the worker and releases ports. Safe to call more than once.
  void dispose() {
    _watchdog?.cancel();
    _watchdog = null;
    _isolate?.kill(priority: Isolate.immediate);
    _fromWorker?.close();
    _isolate = null;
    _toWorker = null;
    _fromWorker = null;
    _busy = false;
    if (_pending != null && !_pending!.isCompleted) _pending!.complete(null);
    _pending = null;
  }
}

/// Frame payload sent to the worker. All fields are isolate-transferable.
class _FrameRequest {
  const _FrameRequest(this.data, this.width, this.height);
  final TransferableTypedData data;
  final int width;
  final int height;
}

/// Worker isolate entry point: handshake, then detect one frame per message.
/// Any failure (buffer materialization, OpenCV) is swallowed into a null reply
/// so the isolate never dies and the preview is never blocked.
void _workerEntry(SendPort toMain) {
  final port = ReceivePort();
  toMain.send(port.sendPort);
  port.listen((msg) {
    if (msg is! _FrameRequest) return;
    LiveDetection? result;
    try {
      final gray = msg.data.materialize().asUint8List();
      final corners = detectCornersInGrayBuffer(gray, msg.width, msg.height);
      result = LiveDetection(
        xs: [for (final p in corners.points) p.x],
        ys: [for (final p in corners.points) p.y],
        detected: corners.detected,
        frameWidth: msg.width,
        frameHeight: msg.height,
      );
    } catch (_) {
      result = null;
    }
    toMain.send(result);
  });
}
