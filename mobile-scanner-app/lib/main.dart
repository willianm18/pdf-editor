import 'package:flutter/material.dart';

import 'screens/home_screen.dart';

void main() {
  runApp(const StirlingScannerApp());
}

class StirlingScannerApp extends StatelessWidget {
  const StirlingScannerApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Stirling Scanner',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF0F6CBD)),
        useMaterial3: true,
      ),
      home: const HomeScreen(),
    );
  }
}
