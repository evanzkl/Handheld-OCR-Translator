import 'package:flutter/material.dart';

import 'screens/home_screen.dart';

void main() {
  runApp(const OcrTranslatorApp());
}

class OcrTranslatorApp extends StatelessWidget {
  const OcrTranslatorApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Handheld OCR Translator',
      theme: ThemeData(colorSchemeSeed: const Color(0xFF243450), useMaterial3: true),
      home: const HomeScreen(),
    );
  }
}
