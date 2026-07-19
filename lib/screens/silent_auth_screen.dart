import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:webview_flutter/webview_flutter.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'live_transcript_screen.dart';

class SilentAuthScreen extends StatefulWidget {
  final String originalUrl;
  final String resolvedUrl;

  const SilentAuthScreen({
    super.key,
    required this.originalUrl,
    required this.resolvedUrl,
  });

  @override
  State<SilentAuthScreen> createState() => _SilentAuthScreenState();
}

class _SilentAuthScreenState extends State<SilentAuthScreen> {
  late WebViewController _controller;
  bool _isAuthenticated = false;
  final FlutterSecureStorage _storage = const FlutterSecureStorage();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Loading…'),
        automaticallyImplyLeading: false,
      ),
      body: WebView(
        initialUrl: widget.originalUrl,
        javascriptMode: JavascriptMode.unrestricted,
        onWebViewCreated: (WebViewController controller) {
          _controller = controller;
        },
        onPageFinished: _onPageFinished,
        onWebResourceError: (error) {
          if (kDebugMode) {
            print('WebView error: $error');
          }
          _showError('Failed to load the page.');
        },
      ),
    );
  }

  Future<void> _onPageFinished(String url) async {
    try {
      // v2 API: use runJavascriptReturningResult instead of deprecated evaluateJavascript.
      final cookiesResult = await _controller.runJavascriptReturningResult('document.cookie');
      final cookies = cookiesResult.replaceAll(RegExp(r'^"(.*)"$'), r'$1');
      if (cookies.isNotEmpty && cookies.contains('_forward_auth_csrf')) {
        await _storage.write(key: 'cookies', value: cookies);
        if (mounted && !_isAuthenticated) {
          setState(() => _isAuthenticated = true);
          Navigator.pushReplacement(
            context,
            MaterialPageRoute(
              builder: (_) => LiveTranscriptScreen(
                resolvedUrl: widget.resolvedUrl,
                originalUrl: widget.originalUrl,
              ),
            ),
          );
        }
      }
    } catch (e) {
      if (kDebugMode) {
        print('Error extracting cookies: $e');
      }
    }
  }

  void _showError(String message) {
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(message)),
      );
    }
  }
}