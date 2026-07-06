import 'package:asr_live_translator/screens/session_selection_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show kIsWeb, defaultTargetPlatform;
import 'package:firebase_core/firebase_core.dart';
import 'screens/qr_scanner_screen.dart';
import 'screens/live_transcript_screen.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Firebase initialization
  if (kIsWeb) {
    const firebaseOptions = FirebaseOptions(
      apiKey: "AIzaSyDzSrmUy6SB2mSj0IZ3lOIJZ4de5fmps4w",
      authDomain: "lectureviewerapp.firebaseapp.com",
      projectId: "lectureviewerapp",
      storageBucket: "lectureviewerapp.firebasestorage.app",
      messagingSenderId: "844850086526",
      appId: "1:844850086526:web:916ab321abf65eaa818e2f",
      measurementId: "G-EJM5LW14VS",
    );
    await Firebase.initializeApp(options: firebaseOptions);
  } else if (defaultTargetPlatform == TargetPlatform.android ||
             defaultTargetPlatform == TargetPlatform.iOS) {
    // Mobile: uses google-services.json / GoogleService-Info.plist
    await Firebase.initializeApp();
  } else {
    // Desktop (Windows, macOS, Linux): skip Firebase initialization
    // The app will handle missing Firebase with try-catch in live_transcript_screen.
    // If you want Firebase on desktop, uncomment the block below and provide your
    // Firebase web configuration (same as web options).
    
    const firebaseOptions = FirebaseOptions(
      apiKey: "AIzaSyDzSrmUy6SB2mSj0IZ3lOIJZ4de5fmps4w",
      authDomain: "lectureviewerapp.firebaseapp.com",
      projectId: "lectureviewerapp",
      storageBucket: "lectureviewerapp.firebasestorage.app",
      messagingSenderId: "844850086526",
      appId: "1:844850086526:web:916ab321abf65eaa818e2f",
      measurementId: "G-EJM5LW14VS",
    );
    await Firebase.initializeApp(options: firebaseOptions);
    
  }

  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'ASR Live Translator',
      theme: ThemeData(useMaterial3: true),
      initialRoute: '/',
      routes: {
        '/': (context) => const SessionSelectionScreen(),
        '/scan': (context) => const QRScannerScreen(),
        '/live': (context) => LiveTranscriptScreen(
              initialUrl: ModalRoute.of(context)!.settings.arguments as String,
            ),
      },
    );
  }
}