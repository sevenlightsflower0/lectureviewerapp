import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'screens/qr_scanner_screen.dart';
import 'screens/live_transcript_screen.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp();
  final prefs = await SharedPreferences.getInstance();
  final savedUrl = prefs.getString('session_url');
  runApp(MyApp(initialUrl: savedUrl));
}

class MyApp extends StatelessWidget {
  final String? initialUrl;
  const MyApp({super.key, this.initialUrl});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'ASR Live Translator',
      theme: ThemeData(useMaterial3: true),
      initialRoute: initialUrl == null ? '/scan' : '/live',
      routes: {
        '/scan': (context) => const QRScannerScreen(),
        '/live': (context) {
          final args = ModalRoute.of(context)!.settings.arguments as String?;
          final url = args ?? initialUrl;
          if (url == null) return const QRScannerScreen();
          return LiveTranscriptScreen(initialUrl: url);
        },
      },
    );
  }
}