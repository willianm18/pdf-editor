import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:opencv_dart/opencv_dart.dart' as cv;

/// Manual document-enhancement filters, ported almost 1:1 from the web
/// implementation at `frontend/editor/src/core/utils/imageEnhance.ts`.
///
/// The web version runs OpenCV.js on `ImageData`; here we run dartcv4 (OpenCV
/// native) on files. Two conventions carried over from the reference:
///   * All heavy work happens off the main thread (there: ready for a Web
///     Worker; here: `Isolate.run`).
///   * Every native `Mat`/`CLAHE`/`VecMat` is released in a `finally` block —
///     dartcv4 has finalizers, but large images must not wait for the GC.
///
/// Colour convention: `imread`/`imencode` speak BGR, but every parameter below
/// (saturation gains, white-balance clamps, gamma) was tuned in the web code
/// against RGB. So each pipeline converts BGR->RGB up front and RGB->BGR before
/// encoding, and reasons in RGB throughout — one convention, matching the
/// cheat-sheet's guidance for visual parity.

/// Selectable enhancement styles offered on the review screen.
/// Mirrors the `EnhanceFilter` union in imageEnhance.ts.
enum EnhanceFilter {
  magicColor,
  colorDocument,
  clarear,
  grayscale,
  blackAndWhite,
  original,
}

/// PT-BR labels for the filter strip in the UI.
extension EnhanceFilterLabel on EnhanceFilter {
  String get label => switch (this) {
        EnhanceFilter.magicColor => 'Magic Color',
        EnhanceFilter.colorDocument => 'Documento Colorido',
        EnhanceFilter.clarear => 'Clarear',
        EnhanceFilter.grayscale => 'Tons de Cinza',
        EnhanceFilter.blackAndWhite => 'P&B',
        EnhanceFilter.original => 'Original',
      };
}

/// If true, the heavy OpenCV work runs in a background isolate via
/// `Isolate.run`. If dartcv4's native FFI ever misbehaves inside a spawned
/// isolate on-device, flip this to `false` to run the exact same code
/// synchronously on the caller's isolate — the only difference is where the
/// central `_encodeInIsolate`/`_writeInIsolate` functions execute. This is the
/// single swap point the brief asked to keep isolated and commented.
const bool _useIsolate = true;

/// Applies [filter] to [srcPath] and returns the encoded bytes (JPEG q=82 for
/// every filter EXCEPT [EnhanceFilter.blackAndWhite], which is a bilevel PNG).
/// When [maxWidth] is set, the image is downscaled to that width first — used
/// for the fast filter-strip thumbnails.
///
/// Equivalent to the web `enhanceImageData` + `imageDataToDataUrl` pair.
Future<Uint8List> enhanceToBytes({
  required String srcPath,
  required EnhanceFilter filter,
  int? maxWidth,
}) {
  final req = _EnhanceRequest(
    srcPath: _toFilePath(srcPath),
    filterIndex: filter.index,
    maxWidth: maxWidth,
  );
  return _useIsolate
      ? Isolate.run(() => _encodeInIsolate(req))
      : Future.value(_encodeInIsolate(req));
}

/// Applies [filter] at full resolution, writes the result to a fresh temp file
/// and returns its path (for the multipart upload). For
/// [EnhanceFilter.original] no work is needed, so [srcPath] is returned as-is.
Future<String> enhanceToFile({
  required String srcPath,
  required EnhanceFilter filter,
}) {
  final path = _toFilePath(srcPath);
  if (filter == EnhanceFilter.original) return Future.value(path);

  final ext = filter == EnhanceFilter.blackAndWhite ? 'png' : 'jpg';
  final outPath = _tempPath(ext);
  final req = _EnhanceRequest(
    srcPath: path,
    filterIndex: filter.index,
    maxWidth: null,
    outPath: outPath,
  );
  return _useIsolate
      ? Isolate.run(() => _writeInIsolate(req))
      : Future.value(_writeInIsolate(req));
}

/// Rotates [srcPath] 90 degrees clockwise, writes a fresh file and returns its
/// path. Format is preserved by extension (defaults to jpg).
Future<String> rotate90({required String srcPath}) {
  final path = _toFilePath(srcPath);
  final ext = path.toLowerCase().endsWith('.png') ? 'png' : 'jpg';
  final outPath = _tempPath(ext);
  final req = _RotateRequest(srcPath: path, outPath: outPath);
  return _useIsolate
      ? Isolate.run(() => _rotateInIsolate(req))
      : Future.value(_rotateInIsolate(req));
}

// --- Isolate payloads (serializable only: String/int/int?) -----------------
// Never pass a Mat across an isolate boundary — Mats are native pointers.

class _EnhanceRequest {
  const _EnhanceRequest({
    required this.srcPath,
    required this.filterIndex,
    required this.maxWidth,
    this.outPath,
  });

  final String srcPath;
  final int filterIndex;
  final int? maxWidth;
  final String? outPath;
}

class _RotateRequest {
  const _RotateRequest({required this.srcPath, required this.outPath});

  final String srcPath;
  final String outPath;
}

// --- Isolate entry points ---------------------------------------------------
// Each opens its own Mats, processes, encodes/writes, and disposes everything
// before returning a plain value.

Uint8List _encodeInIsolate(_EnhanceRequest req) {
  final filter = EnhanceFilter.values[req.filterIndex];
  cv.Mat? processed;
  try {
    processed = _loadAndProcess(req.srcPath, filter, req.maxWidth);
    return _encode(processed, filter);
  } finally {
    processed?.dispose();
  }
}

String _writeInIsolate(_EnhanceRequest req) {
  final filter = EnhanceFilter.values[req.filterIndex];
  cv.Mat? processed;
  try {
    processed = _loadAndProcess(req.srcPath, filter, req.maxWidth);
    final params = filter == EnhanceFilter.blackAndWhite
        ? cv.VecI32.fromList([cv.IMWRITE_PNG_BILEVEL, 1])
        : cv.VecI32.fromList([cv.IMWRITE_JPEG_QUALITY, 82]);
    try {
      cv.imwrite(req.outPath!, processed, params: params);
    } finally {
      params.dispose();
    }
    return req.outPath!;
  } finally {
    processed?.dispose();
  }
}

String _rotateInIsolate(_RotateRequest req) {
  final src = cv.imread(req.srcPath);
  cv.Mat? rotated;
  try {
    rotated = cv.rotate(src, cv.ROTATE_90_CLOCKWISE);
    cv.imwrite(req.outPath, rotated);
    return req.outPath;
  } finally {
    src.dispose();
    rotated?.dispose();
  }
}

// --- Central load + dispatch ------------------------------------------------

/// Reads [path] (BGR), optionally downscales to [maxWidth], converts to RGB and
/// runs [filter]. Returns a BGR Mat ready for encoding; caller disposes it.
cv.Mat _loadAndProcess(String path, EnhanceFilter filter, int? maxWidth) {
  final bgr = cv.imread(path);
  try {
    final scaled = _maybeDownscale(bgr, maxWidth);
    try {
      // BGR -> RGB so the web-tuned parameters apply as-is.
      final rgb = cv.cvtColor(scaled, cv.COLOR_BGR2RGB);
      cv.Mat? result;
      try {
        result = switch (filter) {
          EnhanceFilter.magicColor => _magicColor(rgb),
          EnhanceFilter.colorDocument => _colorDocument(rgb),
          EnhanceFilter.clarear => _clarear(rgb),
          EnhanceFilter.grayscale => _grayscale(rgb),
          EnhanceFilter.blackAndWhite => _blackAndWhite(rgb),
          EnhanceFilter.original => rgb.clone(),
        };
        // blackAndWhite / grayscale return single-channel results that encode
        // directly; the colour filters are RGB and need RGB -> BGR before
        // imencode/imwrite.
        if (result.channels == 3) {
          final out = cv.cvtColor(result, cv.COLOR_RGB2BGR);
          result.dispose();
          result = null; // avoid the `finally` disposing it a second time
          return out;
        }
        final out = result;
        result = null;
        return out;
      } finally {
        result?.dispose();
        rgb.dispose();
      }
    } finally {
      if (!identical(scaled, bgr)) scaled.dispose();
    }
  } finally {
    bgr.dispose();
  }
}

/// Downscale to [maxWidth] preserving aspect ratio (INTER_AREA = best for
/// shrinking). Returns [src] unchanged when no scaling is needed so callers can
/// tell with `identical`.
cv.Mat _maybeDownscale(cv.Mat src, int? maxWidth) {
  if (maxWidth == null || src.cols <= maxWidth) return src;
  final height = (src.rows * maxWidth / src.cols).round();
  return cv.resize(src, (maxWidth, height), interpolation: cv.INTER_AREA);
}

Uint8List _encode(cv.Mat img, EnhanceFilter filter) {
  // B&W stays PNG (bilevel — JPEG would ring around text); everything else is
  // JPEG q=82. Mirrors imageDataToDataUrl in the web version.
  if (filter == EnhanceFilter.blackAndWhite) {
    final params = cv.VecI32.fromList([cv.IMWRITE_PNG_BILEVEL, 1]);
    try {
      final (_, bytes) = cv.imencode('.png', img, params: params);
      return bytes;
    } finally {
      params.dispose();
    }
  }
  final params = cv.VecI32.fromList([cv.IMWRITE_JPEG_QUALITY, 82]);
  try {
    final (_, bytes) = cv.imencode('.jpg', img, params: params);
    return bytes;
  } finally {
    params.dispose();
  }
}

// --- Shared helpers (ports of the web helpers) ------------------------------

/// Alpha/beta for `convertScaleAbs` that stretch a single-channel histogram so
/// the given low/high percentiles map to 0/255 (CamScanner-style
/// auto-contrast). Port of `autoContrastParams`.
(double alpha, double beta) _autoContrastParams(
  cv.Mat gray, {
  double clipLow = 0.01,
  double clipHigh = 0.99,
}) {
  final data = gray.data;
  final hist = List<int>.filled(256, 0);
  for (var i = 0; i < data.length; i++) {
    hist[data[i]]++;
  }
  final total = data.length;
  final lowCount = total * clipLow;
  final highCount = total * clipHigh;

  var cumulative = 0;
  var lowValue = 0;
  var highValue = 255;
  for (var v = 0; v < 256; v++) {
    cumulative += hist[v];
    if (cumulative <= lowCount) lowValue = v;
    if (cumulative <= highCount) highValue = v;
  }
  if (highValue <= lowValue) {
    lowValue = 0;
    highValue = 255;
  }
  final alpha = 255 / (highValue - lowValue);
  final beta = -lowValue * alpha;
  return (alpha, beta);
}

/// Flatten uneven lighting: estimate the background with a large morphological
/// close, then divide the source by it. Port of `removeShadow`. Single-channel
/// in, single-channel out; caller disposes.
cv.Mat _removeShadow(cv.Mat gray, {int kernelSize = 21}) {
  final kernel =
      cv.getStructuringElement(cv.MORPH_ELLIPSE, (kernelSize, kernelSize));
  final background = cv.morphologyEx(gray, cv.MORPH_CLOSE, kernel);
  try {
    return cv.divide(gray, background, scale: 255);
  } finally {
    kernel.dispose();
    background.dispose();
  }
}

/// Local-contrast pop that keeps colour: CLAHE on the L channel in LAB space,
/// leaving a/b untouched. Port of `claheOnLuminance`. Returns a new RGB Mat.
cv.Mat _claheOnLuminance(cv.Mat rgb, {double clipLimit = 3.0}) {
  final lab = cv.cvtColor(rgb, cv.COLOR_RGB2Lab);
  final channels = cv.split(lab);
  final clahe = cv.createCLAHE(clipLimit: clipLimit, tileGridSize: (8, 8));
  final l = channels[0];
  cv.Mat? enhanced;
  try {
    enhanced = clahe.apply(l);
    channels[0] = enhanced;
    cv.merge(channels, dst: lab);
    return cv.cvtColor(lab, cv.COLOR_Lab2RGB);
  } finally {
    lab.dispose();
    channels.dispose();
    clahe.dispose();
    l.dispose();
    enhanced?.dispose();
  }
}

/// Lighten shadows with a gamma curve on the L channel (gamma < 1 brightens),
/// keeping colour. Port of `lightenLuminance` — but dartcv4 has `cv.LUT`, so
/// the 256-entry curve is applied natively instead of a manual pass. Returns a
/// new RGB Mat.
cv.Mat _lightenLuminance(cv.Mat rgb, {double gamma = 0.7}) {
  final lut = _gammaLut(gamma);
  final lab = cv.cvtColor(rgb, cv.COLOR_RGB2Lab);
  final channels = cv.split(lab);
  final l = channels[0];
  cv.Mat? curved;
  try {
    curved = cv.LUT(l, lut);
    channels[0] = curved;
    cv.merge(channels, dst: lab);
    return cv.cvtColor(lab, cv.COLOR_Lab2RGB);
  } finally {
    lut.dispose();
    lab.dispose();
    channels.dispose();
    l.dispose();
    curved?.dispose();
  }
}

/// 1x256 CV_8UC1 gamma curve `pow(i/255, gamma) * 255`, for `cv.LUT`.
cv.Mat _gammaLut(double gamma) {
  final lut = cv.Mat.zeros(1, 256, cv.MatType.CV_8UC1);
  for (var i = 0; i < 256; i++) {
    final v = (255 * math.pow(i / 255.0, gamma)).round().clamp(0, 255);
    lut.set<int>(0, i, v);
  }
  return lut;
}

/// Unsharp mask: `src = src*(1+amount) - blur*amount`. Port of `sharpen`.
/// Returns a new Mat (1- or 3-channel); caller disposes.
cv.Mat _sharpen(cv.Mat src, {double amount = 0.8}) {
  // ksize (0,0) => derived from sigma; sigma ~2 targets fine document detail.
  final blurred = cv.gaussianBlur(src, (0, 0), 2);
  try {
    return cv.addWeighted(src, 1 + amount, blurred, -amount, 0);
  } finally {
    blurred.dispose();
  }
}

// --- Filters (ports of the web filter functions) ----------------------------

/// White-balance (gray-world) + LAB-CLAHE + auto-contrast + gentle saturation
/// boost + sharpen. Port of `magicColor`. RGB in, RGB out.
cv.Mat _magicColor(cv.Mat rgbIn) {
  var rgb = rgbIn.clone();
  try {
    // Gray-world white balance: scale each channel so their means match.
    // `cv.mean` gives per-channel means directly (val1=R, val2=G, val3=B),
    // matching the web's manual per-channel average.
    final means = cv.mean(rgb);
    final m = [means.val1, means.val2, means.val3]
        .map((e) => e == 0 ? 1.0 : e)
        .toList();
    final grayMean = (m[0] + m[1] + m[2]) / 3;
    final channels = cv.split(rgb);
    try {
      for (var c = 0; c < 3; c++) {
        final ch = channels[c];
        // Clamp the per-channel gain so a strong colour cast can't blow the
        // white balance out into an unnatural tint.
        final gain = (grayMean / m[c]).clamp(0.75, 1.35);
        final scaled = cv.convertScaleAbs(ch, alpha: gain, beta: 0);
        channels[c] = scaled;
        ch.dispose();
        scaled.dispose();
      }
      cv.merge(channels, dst: rgb);
    } finally {
      channels.dispose();
    }

    // Local-contrast pop (LAB CLAHE) — the "enhance/Melhorar" look.
    rgb = _replace(rgb, _claheOnLuminance(rgb, clipLimit: 3.0));

    // Auto-contrast driven by the luminance histogram (white-point stretch).
    final gray = cv.cvtColor(rgb, cv.COLOR_RGB2GRAY);
    final (alpha, beta) = _autoContrastParams(gray);
    gray.dispose();
    rgb = _replace(rgb, cv.convertScaleAbs(rgb, alpha: alpha, beta: beta));

    // Gentle saturation boost in HSV.
    rgb = _replace(rgb, _boostSaturation(rgb, 1.15));

    // Return sharpen's result directly; `rgb` (the current stage) is disposed
    // exactly once by the `finally` below. Using `_replace` here would dispose
    // `rgb` and then `finally` would dispose it again — a double free, since
    // dartcv4's Mat.dispose() is NOT idempotent (it calls cv_Mat_close blindly).
    return _sharpen(rgb);
  } finally {
    rgb.dispose();
  }
}

/// Shadow-flattened colour document: per-channel illumination normalisation
/// that keeps colour, softer local-contrast pop, gentle saturation, sharpen.
/// Port of `colorDocument`. RGB in, RGB out.
cv.Mat _colorDocument(cv.Mat rgbIn) {
  var rgb = rgbIn.clone();
  try {
    final gray = cv.cvtColor(rgb, cv.COLOR_RGB2GRAY);
    final kernel = cv.getStructuringElement(cv.MORPH_ELLIPSE, (21, 21));
    final background = cv.morphologyEx(gray, cv.MORPH_CLOSE, kernel);
    final channels = cv.split(rgb);
    try {
      for (var c = 0; c < 3; c++) {
        final ch = channels[c];
        final normalized = cv.divide(ch, background, scale: 255);
        channels[c] = normalized;
        ch.dispose();
        normalized.dispose();
      }
      cv.merge(channels, dst: rgb);
    } finally {
      gray.dispose();
      kernel.dispose();
      background.dispose();
      channels.dispose();
    }

    // Softer local-contrast pop than magicColor — keeps the natural look.
    rgb = _replace(rgb, _claheOnLuminance(rgb, clipLimit: 2.0));

    // Gentle saturation lift.
    rgb = _replace(rgb, _boostSaturation(rgb, 1.1));

    // Return sharpen's result directly; `rgb` (the current stage) is disposed
    // exactly once by the `finally` below. Using `_replace` here would dispose
    // `rgb` and then `finally` would dispose it again — a double free, since
    // dartcv4's Mat.dispose() is NOT idempotent (it calls cv_Mat_close blindly).
    return _sharpen(rgb);
  } finally {
    rgb.dispose();
  }
}

/// Lighten: gamma curve on luminance + a light sharpen. Port of `clarear`.
/// RGB in, RGB out.
cv.Mat _clarear(cv.Mat rgb) {
  final lightened = _lightenLuminance(rgb, gamma: 0.7);
  try {
    return _sharpen(lightened, amount: 0.4);
  } finally {
    lightened.dispose();
  }
}

/// Grayscale + auto-contrast + sharpen. Port of `grayscale`. RGB in,
/// single-channel gray out.
cv.Mat _grayscale(cv.Mat rgb) {
  final gray = cv.cvtColor(rgb, cv.COLOR_RGB2GRAY);
  cv.Mat? stretched;
  try {
    final (alpha, beta) = _autoContrastParams(gray);
    stretched = cv.convertScaleAbs(gray, alpha: alpha, beta: beta);
    return _sharpen(stretched);
  } finally {
    gray.dispose();
    stretched?.dispose();
  }
}

/// Shadow removal + median denoise + adaptive threshold for crisp bilevel text.
/// Port of `blackAndWhite`. RGB in, single-channel bilevel out.
cv.Mat _blackAndWhite(cv.Mat rgb) {
  final gray = cv.cvtColor(rgb, cv.COLOR_RGB2GRAY);
  cv.Mat? flattened;
  cv.Mat? denoised;
  try {
    flattened = _removeShadow(gray);
    // Median blur kills salt-and-pepper speckle so the threshold stays clean.
    denoised = cv.medianBlur(flattened, 3);
    // blockSize 25 smooths the local threshold; C 12 = cleaner/whiter
    // background (the web default `bwStrength`).
    return cv.adaptiveThreshold(
      denoised,
      255,
      cv.ADAPTIVE_THRESH_GAUSSIAN_C,
      cv.THRESH_BINARY,
      25,
      12,
    );
  } finally {
    gray.dispose();
    flattened?.dispose();
    denoised?.dispose();
  }
}

/// HSV saturation multiplier via `convertScaleAbs` on the S channel. Shared by
/// the two colour filters. RGB in, RGB out; caller disposes.
cv.Mat _boostSaturation(cv.Mat rgb, double saturation) {
  final hsv = cv.cvtColor(rgb, cv.COLOR_RGB2HSV);
  final channels = cv.split(hsv);
  final sat = channels[1];
  cv.Mat? boosted;
  try {
    boosted = cv.convertScaleAbs(sat, alpha: saturation, beta: 0);
    channels[1] = boosted;
    cv.merge(channels, dst: hsv);
    return cv.cvtColor(hsv, cv.COLOR_HSV2RGB);
  } finally {
    hsv.dispose();
    channels.dispose();
    sat.dispose();
    boosted?.dispose();
  }
}

/// Dispose [old] and return [next] — sugar for the `x = f(x); oldX.dispose()`
/// chains above, keeping every intermediate released.
cv.Mat _replace(cv.Mat old, cv.Mat next) {
  old.dispose();
  return next;
}

// --- Paths ------------------------------------------------------------------

String _toFilePath(String pathOrUri) =>
    pathOrUri.startsWith('file://') ? Uri.parse(pathOrUri).toFilePath() : pathOrUri;

String _tempPath(String ext) {
  final name = 'enh_${DateTime.now().microsecondsSinceEpoch}.$ext';
  return '${Directory.systemTemp.path}${Platform.pathSeparator}$name';
}
