import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'screens/home_screen.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await SystemChrome.setPreferredOrientations([
    DeviceOrientation.portraitUp,
  ]);
  runApp(const PuzzleHelperApp());
}

class PuzzleHelperApp extends StatelessWidget {
  const PuzzleHelperApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '拼圖助手 AR',
      debugShowCheckedModeBanner: false,
      themeMode: ThemeMode.dark,
      darkTheme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.dark,
        scaffoldBackgroundColor: const Color(0xFF0F131A),
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF00E676),
          brightness: Brightness.dark,
          primary: const Color(0xFF00E676),
          secondary: Colors.cyanAccent,
        ),
        appBarTheme: const AppBarTheme(
          backgroundColor: Color(0xFF141923),
          foregroundColor: Colors.white,
          elevation: 0,
        ),
      ),
      home: const HomeScreen(),
    );
  }
}
