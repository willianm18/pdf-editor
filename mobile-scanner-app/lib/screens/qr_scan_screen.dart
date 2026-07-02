import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../services/qr_parser.dart';

/// Reads the QR code from the desktop Stirling-PDF app. On a valid QR (one that
/// carries a `session`), stops the camera and pops with the parsed [ScanTarget].
class QrScanScreen extends StatefulWidget {
  const QrScanScreen({super.key});

  @override
  State<QrScanScreen> createState() => _QrScanScreenState();
}

class _QrScanScreenState extends State<QrScanScreen> {
  final MobileScannerController _controller = MobileScannerController(
    formats: const [BarcodeFormat.qrCode],
  );

  // Guards against parsing more frames after the first valid QR.
  bool _handled = false;
  String? _error;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _onDetect(BarcodeCapture capture) async {
    if (_handled) return;
    for (final barcode in capture.barcodes) {
      final value = barcode.rawValue;
      if (value == null || value.isEmpty) continue;

      try {
        final target = parseScanTarget(value);
        _handled = true;
        await _controller.stop();
        if (!mounted) return;
        Navigator.of(context).pop(target);
        return;
      } on QrParseException catch (e) {
        if (mounted) setState(() => _error = e.message);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Ler QR code')),
      body: Stack(
        children: [
          MobileScanner(controller: _controller, onDetect: _onDetect),
          Align(
            alignment: Alignment.bottomCenter,
            child: Container(
              width: double.infinity,
              color: Colors.black54,
              padding: const EdgeInsets.all(16),
              child: Text(
                _error ?? 'Aponte para o QR code exibido no Stirling-PDF.',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: _error != null ? Colors.orangeAccent : Colors.white,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
