import 'package:asr_live_translator/screens/session_selection_screen.dart';
import 'package:firebase_core/firebase_core.dart';  // ✅ correct
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show kIsWeb, defaultTargetPlatform;
// ✅ REMOVED the broken duplicate import
import 'screens/qr_scanner_screen.dart';
import 'screens/live_transcript_screen.dart';
import 'screens/silent_auth_screen.dart';
import 'route_observer.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Firebase initialization...
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
    await Firebase.initializeApp();
  } else {
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
      navigatorObservers: [routeObserver],
      routes: {
        '/': (context) => const SessionSelectionScreen(),
        '/scan': (context) => const QRScannerScreen(),
        '/live': (context) {
          final args = ModalRoute.of(context)!.settings.arguments;
          if (args is Map<String, dynamic>) {
            return LiveTranscriptScreen(
              resolvedUrl: args['resolvedUrl'] as String,
              originalUrl: args['originalUrl'] as String?,
            );
          } else if (args is String) {
            return LiveTranscriptScreen(
              resolvedUrl: args,
              originalUrl: null,
            );
          } else {
            return const Scaffold(
              body: Center(
                child: Text('Invalid navigation arguments'),
              ),
            );
          }
        },
        '/auth': (context) {
          final args = ModalRoute.of(context)!.settings.arguments;
          if (args is Map<String, dynamic>) {
            return SilentAuthScreen(
              originalUrl: args['originalUrl'] as String,
              resolvedUrl: args['resolvedUrl'] as String,
            );
          } else {
            return const Scaffold(
              body: Center(
                child: Text('Missing authentication parameters'),
              ),
            );
          }
        },
      },
    );
  }
}