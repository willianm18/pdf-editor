import 'package:flutter/material.dart';

/// The live-detection quad to draw, expressed in the UPRIGHT (portrait) image
/// space of size [imageWidth]×[imageHeight]. The painter scales these to its
/// own canvas size, so the widget must occupy exactly the same box as the
/// camera preview (same AspectRatio) for the lines to sit on the document.
///
/// [corners] holds 4 points ordered TL, TR, BR, BL. [wellFramed] switches the
/// colour to green as an implicit "you can shoot now" cue.
@immutable
class EdgeOverlayData {
  const EdgeOverlayData({
    required this.corners,
    required this.imageWidth,
    required this.imageHeight,
    required this.wellFramed,
  });

  final List<Offset> corners;
  final double imageWidth;
  final double imageHeight;
  final bool wellFramed;

  @override
  bool operator ==(Object other) =>
      other is EdgeOverlayData &&
      other.wellFramed == wellFramed &&
      other.imageWidth == imageWidth &&
      other.imageHeight == imageHeight &&
      _sameCorners(other.corners, corners);

  @override
  int get hashCode => Object.hash(
        wellFramed,
        imageWidth,
        imageHeight,
        Object.hashAll(corners),
      );

  static bool _sameCorners(List<Offset> a, List<Offset> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}

/// Draws the detected document outline over the camera preview. Renders nothing
/// when [data] is null (no confident detection) so the preview stays clean.
class EdgeOverlayPainter extends CustomPainter {
  const EdgeOverlayPainter(this.data);

  final EdgeOverlayData? data;

  // greenAccent / white kept as explicit ARGB to avoid withOpacity deprecation.
  static const Color _detectedLine = Color(0xFFFFFFFF);
  static const Color _goodLine = Color(0xFF69F0AE);
  static const Color _detectedFill = Color(0x22FFFFFF);
  static const Color _goodFill = Color(0x2269F0AE);
  static const Color _halo = Color(0x66000000);

  @override
  void paint(Canvas canvas, Size size) {
    final d = data;
    if (d == null || d.corners.length != 4) return;
    if (d.imageWidth <= 0 || d.imageHeight <= 0) return;

    final sx = size.width / d.imageWidth;
    final sy = size.height / d.imageHeight;
    final pts = [for (final c in d.corners) Offset(c.dx * sx, c.dy * sy)];
    final path = Path()..addPolygon(pts, true);

    final lineColor = d.wellFramed ? _goodLine : _detectedLine;
    final fillColor = d.wellFramed ? _goodFill : _detectedFill;

    canvas.drawPath(path, Paint()..color = fillColor);
    // Dark halo underneath keeps the line visible over light documents.
    canvas.drawPath(
      path,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 5
        ..color = _halo,
    );
    canvas.drawPath(
      path,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3
        ..strokeJoin = StrokeJoin.round
        ..color = lineColor,
    );
    final dot = Paint()..color = lineColor;
    for (final p in pts) {
      canvas.drawCircle(p, 5, dot);
    }
  }

  @override
  bool shouldRepaint(EdgeOverlayPainter oldDelegate) => oldDelegate.data != data;
}
