import 'package:flutter/material.dart';
import 'screens/home_screen.dart';

void main() {
  runApp(const OrionApp());
}

class OrionApp extends StatelessWidget {
  const OrionApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Orion',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark().copyWith(
        scaffoldBackgroundColor: const Color(0xFF0A0A0A),
        colorScheme: const ColorScheme.dark(
          primary: Color(0xFF00D4FF),
          surface: Color(0xFF111111),
        ),
      ),
      home: const HomeScreen(),
    );
  }
}
