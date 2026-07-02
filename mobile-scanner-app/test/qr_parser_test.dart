import 'package:flutter_test/flutter_test.dart';
import 'package:stirling_scanner/services/qr_parser.dart';

void main() {
  group('parseScanTarget', () {
    test('parses an http URL with an explicit port', () {
      final target = parseScanTarget(
        'http://192.168.0.10:8080/mobile-scanner?session=abc123',
      );
      expect(target.origin, 'http://192.168.0.10:8080');
      expect(target.sessionId, 'abc123');
      expect(
        target.uploadUrl,
        'http://192.168.0.10:8080/api/v1/mobile-scanner/upload/abc123',
      );
    });

    test('parses a URL without a port', () {
      final target = parseScanTarget(
        'http://example.com/mobile-scanner?session=xyz',
      );
      expect(target.origin, 'http://example.com');
      expect(target.sessionId, 'xyz');
      expect(
        target.uploadUrl,
        'http://example.com/api/v1/mobile-scanner/upload/xyz',
      );
    });

    test('parses an https URL', () {
      final target = parseScanTarget(
        'https://stirling.example.com/mobile-scanner?session=SID',
      );
      expect(target.origin, 'https://stirling.example.com');
      expect(target.sessionId, 'SID');
    });

    test('keeps the session even with extra query parameters', () {
      final target = parseScanTarget(
        'https://host/mobile-scanner?foo=1&session=s2&bar=2',
      );
      expect(target.sessionId, 's2');
      expect(target.origin, 'https://host');
    });

    test('throws when the session parameter is absent', () {
      expect(
        () => parseScanTarget('https://host/mobile-scanner'),
        throwsA(isA<QrParseException>()),
      );
    });

    test('throws when the session parameter is empty', () {
      expect(
        () => parseScanTarget('https://host/mobile-scanner?session='),
        throwsA(isA<QrParseException>()),
      );
    });

    test('throws for a non-http(s) scheme', () {
      expect(
        () => parseScanTarget('ftp://host/mobile-scanner?session=s'),
        throwsA(isA<QrParseException>()),
      );
    });
  });
}
