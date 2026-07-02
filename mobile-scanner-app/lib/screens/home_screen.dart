import 'package:flutter/material.dart';

import '../services/qr_parser.dart';
import 'qr_scan_screen.dart';
import 'scan_flow_screen.dart';

/// Landing screen: title + a single large "scan a document" call to action.
class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  Future<void> _startFlow(BuildContext context) async {
    final target = await Navigator.of(context).push<ScanTarget>(
      MaterialPageRoute(builder: (_) => const QrScanScreen()),
    );
    if (target == null || !context.mounted) return;

    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => ScanFlowScreen(target: target)),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Stirling Scanner')),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.document_scanner_outlined, size: 96),
              const SizedBox(height: 16),
              Text(
                'Stirling Scanner',
                style: Theme.of(context).textTheme.headlineMedium,
              ),
              const SizedBox(height: 8),
              Text(
                'Leia o QR do Stirling-PDF, escaneie o documento e envie.',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodyMedium,
              ),
              const SizedBox(height: 40),
              SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  onPressed: () => _startFlow(context),
                  icon: const Icon(Icons.qr_code_scanner),
                  label: const Padding(
                    padding: EdgeInsets.symmetric(vertical: 12),
                    child: Text('Escanear documento',
                        style: TextStyle(fontSize: 18)),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
