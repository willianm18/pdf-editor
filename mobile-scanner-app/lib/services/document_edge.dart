import 'dart:io';
import 'dart:isolate';
import 'dart:math' show Point, atan2, sqrt;
import 'dart:typed_data';

import 'package:opencv_dart/opencv_dart.dart' as cv;

/// Document-edge detection and perspective crop, used by the capture screen's
/// auto-crop and the review screen's manual "Cortar e girar" tab.
///
/// Colour convention: detection works on a grayscale copy (edges don't need
/// colour); the warp itself operates on the original BGR file so no colour
/// information is lost. Every intermediate `Mat`/`VecVecPoint`/`VecPoint` is
/// released in a `finally` block, mirroring `image_enhance.dart` — and same
/// caution applies: `Mat.dispose()` is NOT idempotent, so no Mat is disposed
/// twice on any path.

/// Result of [detectDocumentCorners]: four corners in source-image pixel
/// coordinates, ordered top-left, top-right, bottom-right, bottom-left, plus
/// whether they came from a real detection or the whole-image fallback (used
/// by the crop UI to hint the user visually).
class DocumentCorners {
  const DocumentCorners({required this.points, required this.detected});

  final List<Point<double>> points;
  final bool detected;
}

/// Detects the largest quadrilateral in the image at [path] and returns its
/// four corners. Falls back to the image's own four corners (marked
/// `detected: false`) when no suitable quadrilateral is found.
Future<DocumentCorners> detectDocumentCorners(String path) {
  final req = _DetectRequest(srcPath: _toFilePath(path));
  return Isolate.run(() => _detectInIsolate(req));
}

/// Applies a perspective warp so [corners] (in [srcPath]'s pixel coordinates,
/// same ordering as [DocumentCorners.points]) become the new image's
/// rectangular bounds. Writes the result to a fresh temp file and returns its
/// path. Format is preserved by extension (defaults to jpg).
Future<String> warpToCorners(String srcPath, List<Point<double>> corners) {
  if (corners.length != 4) {
    throw ArgumentError.value(
      corners.length,
      'corners.length',
      'warpToCorners requires exactly 4 corners',
    );
  }
  final path = _toFilePath(srcPath);
  final ext = path.toLowerCase().endsWith('.png') ? 'png' : 'jpg';
  final outPath = _tempPath(ext);
  final req = _WarpRequest(
    srcPath: path,
    outPath: outPath,
    xs: [for (final p in corners) p.x],
    ys: [for (final p in corners) p.y],
  );
  return Isolate.run(() => _warpInIsolate(req));
}

// --- Isolate payloads (serializable only) -----------------------------------

class _DetectRequest {
  const _DetectRequest({required this.srcPath});
  final String srcPath;
}

class _WarpRequest {
  const _WarpRequest({
    required this.srcPath,
    required this.outPath,
    required this.xs,
    required this.ys,
  });
  final String srcPath;
  final String outPath;
  final List<double> xs;
  final List<double> ys;
}

// --- Isolate entry points ----------------------------------------------------

DocumentCorners _detectInIsolate(_DetectRequest req) {
  final src = cv.imread(req.srcPath);
  try {
    return _findDocumentQuad(src);
  } finally {
    src.dispose();
  }
}

String _warpInIsolate(_WarpRequest req) {
  final src = cv.imread(req.srcPath);
  cv.Mat? transform;
  cv.Mat? warped;
  cv.VecPoint? srcPts;
  cv.VecPoint? dstPts;
  try {
    final width = _quadWidth(req.xs, req.ys).round().clamp(1, 1 << 20);
    final height = _quadHeight(req.xs, req.ys).round().clamp(1, 1 << 20);

    srcPts = cv.VecPoint.fromList([
      for (var i = 0; i < 4; i++) cv.Point(req.xs[i].round(), req.ys[i].round()),
    ]);
    dstPts = cv.VecPoint.fromList([
      cv.Point(0, 0),
      cv.Point(width - 1, 0),
      cv.Point(width - 1, height - 1),
      cv.Point(0, height - 1),
    ]);

    transform = cv.getPerspectiveTransform(srcPts, dstPts);
    warped = cv.warpPerspective(src, transform, (width, height));
    cv.imwrite(req.outPath, warped);
    return req.outPath;
  } finally {
    src.dispose();
    transform?.dispose();
    warped?.dispose();
    srcPts?.dispose();
    dstPts?.dispose();
  }
}

// --- Detection ----------------------------------------------------------------

/// Finds the largest 4-point convex contour in [src] (a BGR image) via
/// `findContours`/`approxPolyDP`. Falls back to the whole-image rectangle
/// when no such contour clears the area/convexity bar.
DocumentCorners _findDocumentQuad(cv.Mat src) {
  final gray = cv.cvtColor(src, cv.COLOR_BGR2GRAY);
  try {
    return _findQuadFromGray(gray);
  } finally {
    gray.dispose();
  }
}

/// Same detection as [_findDocumentQuad] but starting from an already
/// single-channel (grayscale) [gray] — skips the BGR→gray conversion. Used by
/// the live per-frame path (camera Y plane is already luminance). Does NOT
/// dispose [gray]: ownership stays with the caller (Mat.dispose is not
/// idempotent, so disposing here would risk a native double-free).
DocumentCorners _findQuadFromGray(cv.Mat gray) {
  cv.Mat? blurred;
  cv.Mat? edges;
  cv.VecVecPoint? contours;
  cv.VecVec4i? hierarchy;
  try {
    blurred = cv.gaussianBlur(gray, (5, 5), 0);
    edges = cv.canny(blurred, 50, 150);
    // Dilate to close small gaps in the document outline before contour walk.
    final dilateKernel = cv.getStructuringElement(cv.MORPH_RECT, (3, 3));
    cv.Mat? dilated;
    try {
      dilated = cv.dilate(edges, dilateKernel);
      (contours, hierarchy) = cv.findContours(dilated, cv.RETR_LIST, cv.CHAIN_APPROX_SIMPLE);
    } finally {
      dilateKernel.dispose();
      dilated?.dispose();
    }

    final imageArea = (gray.cols * gray.rows).toDouble();
    List<Point<double>>? best;
    var bestArea = 0.0;

    for (var i = 0; i < contours.length; i++) {
      final contour = contours[i];
      cv.VecPoint? approx;
      try {
        final peri = cv.arcLength(contour, true);
        approx = cv.approxPolyDP(contour, 0.02 * peri, true);
        if (approx.length != 4) continue;
        final area = cv.contourArea(approx);
        // Ignore slivers and anything smaller than 15% of the frame — too
        // small to plausibly be the scanned document.
        if (area < imageArea * 0.15) continue;
        if (!cv.isContourConvex(approx)) continue;
        if (area > bestArea) {
          bestArea = area;
          best = [for (final p in approx) Point(p.x.toDouble(), p.y.toDouble())];
        }
      } finally {
        approx?.dispose();
      }
    }

    if (best != null) {
      return DocumentCorners(points: _orderCorners(best), detected: true);
    }
    return DocumentCorners(points: _wholeImageCorners(gray), detected: false);
  } finally {
    blurred?.dispose();
    edges?.dispose();
    contours?.dispose();
    hierarchy?.dispose();
  }
}

/// Detects document corners in an in-memory single-channel (grayscale) buffer
/// [gray] of size [width]×[height] (row-major, contiguous, no row padding).
///
/// Runs SYNCHRONOUSLY on the calling isolate — intended to be driven from a
/// worker isolate for live per-frame detection. Downscales to [maxSide] on the
/// long edge before the contour walk (detection quality is fine at low res and
/// it keeps each frame cheap), then rescales the corners back to full-frame
/// pixel coordinates so the caller's coordinate math uses the original
/// [width]/[height].
///
/// Best-effort and never throws for a failed detection: returns the whole-image
/// rectangle with `detected: false` when no confident quad is found (callers
/// should hide the overlay in that case).
DocumentCorners detectCornersInGrayBuffer(
  Uint8List gray,
  int width,
  int height, {
  int maxSide = 400,
}) {
  // fromList copies the bytes into the Mat, so it's safe against the camera
  // recycling the frame buffer after this call returns.
  final full = cv.Mat.fromList(height, width, cv.MatType.CV_8UC1, gray);
  cv.Mat? small;
  try {
    final longSide = width > height ? width : height;
    if (longSide <= maxSide) {
      return _findQuadFromGray(full);
    }
    final scale = maxSide / longSide;
    final w = (width * scale).round().clamp(1, width);
    final h = (height * scale).round().clamp(1, height);
    small = cv.resize(full, (w, h), interpolation: cv.INTER_AREA);
    final corners = _findQuadFromGray(small);
    if (!corners.detected) return corners; // detected:false → caller hides it
    final inv = 1.0 / scale;
    return DocumentCorners(
      points: [for (final p in corners.points) Point(p.x * inv, p.y * inv)],
      detected: true,
    );
  } finally {
    full.dispose();
    small?.dispose();
  }
}

List<Point<double>> _wholeImageCorners(cv.Mat src) {
  final w = src.cols.toDouble();
  final h = src.rows.toDouble();
  return [
    const Point(0, 0),
    Point(w - 1, 0),
    Point(w - 1, h - 1),
    Point(0, h - 1),
  ];
}

/// Orders 4 arbitrary points as top-left, top-right, bottom-right, bottom-left.
///
/// Ordered by angle about the centroid (image coords are y-down, so increasing
/// atan2 walks clockwise), then rotated so index 0 is the top-left-most point
/// (smallest x+y). Unlike the classic sum/difference trick, this never assigns
/// the same physical corner to two slots when the document is held near 45°
/// (which collapsed the quad and made its area — hence the "well framed" cue —
/// read far too small).
List<Point<double>> _orderCorners(List<Point<double>> pts) {
  final n = pts.length;
  final cx = pts.map((p) => p.x).reduce((a, b) => a + b) / n;
  final cy = pts.map((p) => p.y).reduce((a, b) => a + b) / n;
  final byAngle = [...pts]
    ..sort((a, b) =>
        atan2(a.y - cy, a.x - cx).compareTo(atan2(b.y - cy, b.x - cx)));
  var start = 0;
  for (var i = 1; i < n; i++) {
    if (byAngle[i].x + byAngle[i].y < byAngle[start].x + byAngle[start].y) {
      start = i;
    }
  }
  return [for (var i = 0; i < n; i++) byAngle[(start + i) % n]];
}

double _quadWidth(List<double> xs, List<double> ys) {
  final top = _distance(xs[0], ys[0], xs[1], ys[1]);
  final bottom = _distance(xs[3], ys[3], xs[2], ys[2]);
  return top > bottom ? top : bottom;
}

double _quadHeight(List<double> xs, List<double> ys) {
  final left = _distance(xs[0], ys[0], xs[3], ys[3]);
  final right = _distance(xs[1], ys[1], xs[2], ys[2]);
  return (left > right ? left : right);
}

double _distance(double x1, double y1, double x2, double y2) {
  final dx = x2 - x1;
  final dy = y2 - y1;
  return sqrt(dx * dx + dy * dy);
}

// --- Paths --------------------------------------------------------------------

String _toFilePath(String pathOrUri) =>
    pathOrUri.startsWith('file://') ? Uri.parse(pathOrUri).toFilePath() : pathOrUri;

String _tempPath(String ext) {
  final name = 'crop_${DateTime.now().microsecondsSinceEpoch}.$ext';
  return '${Directory.systemTemp.path}${Platform.pathSeparator}$name';
}
