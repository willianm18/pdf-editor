/// Pure parsing of the QR code shown by the Stirling-PDF web app.
///
/// The QR encodes a URL like:
///   http(s)://HOST[:PORT]/mobile-scanner?session=SESSIONID
/// (it may carry extra query parameters).
///
/// We assume the API lives at the root of the same origin as the page URL —
/// this holds for both the dev proxy and the same-origin deploy, which is the
/// only way the desktop app hands out these QR codes.
library;

/// Result of parsing a scanned QR value into an upload target.
class ScanTarget {
  const ScanTarget({required this.origin, required this.sessionId});

  /// Scheme + host + optional port, e.g. `https://host:8080`.
  final String origin;

  /// The `session` query parameter from the QR URL.
  final String sessionId;

  /// The full upload endpoint: `{origin}/api/v1/mobile-scanner/upload/{session}`.
  String get uploadUrl =>
      '$origin/api/v1/mobile-scanner/upload/$sessionId';

  @override
  String toString() => 'ScanTarget(origin: $origin, sessionId: $sessionId)';
}

/// Thrown when a scanned QR value is not a valid Stirling-PDF scanner URL.
class QrParseException implements Exception {
  const QrParseException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Parses [qrValue] into a [ScanTarget], or throws [QrParseException] when the
/// value is not a usable Stirling-PDF mobile-scanner URL.
ScanTarget parseScanTarget(String qrValue) {
  final Uri uri;
  try {
    uri = Uri.parse(qrValue.trim());
  } on FormatException {
    throw const QrParseException('QR code is not a valid URL.');
  }

  if (uri.scheme != 'http' && uri.scheme != 'https') {
    throw const QrParseException('QR code must be an http or https URL.');
  }
  if (uri.host.isEmpty) {
    throw const QrParseException('QR code URL is missing a host.');
  }

  final session = uri.queryParameters['session'];
  if (session == null || session.isEmpty) {
    throw const QrParseException('QR code is missing the session parameter.');
  }

  final origin =
      '${uri.scheme}://${uri.host}${uri.hasPort ? ':${uri.port}' : ''}';

  return ScanTarget(origin: origin, sessionId: session);
}
