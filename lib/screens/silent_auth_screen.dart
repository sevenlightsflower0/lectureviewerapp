import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:webview_windows/webview_windows.dart';
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
  WebviewController? _controller;
  bool _isLoading = true;
  bool _isAuthenticated = false;
  final FlutterSecureStorage _storage = const FlutterSecureStorage();

  @override
  void initState() {
    super.initState();
    _initWebView();
  }

  Future<void> _initWebView() async {
    try {
      final controller = WebviewController();
      await controller.initialize();
      await controller.loadUrl(widget.originalUrl);
      if (mounted) {
        setState(() {
          _controller = controller;
          _isLoading = false;
        });
        // Start periodic cookie check
        _checkCookies();
      }
    } catch (e) {
      if (kDebugMode) print('WebView init error: $e');
      if (mounted) {
        setState(() => _isLoading = false);
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Failed to load the page. Please try again.')),
        );
      }
    }
  }

  Future<void> _checkCookies() async {
    if (_controller == null || !mounted || _isAuthenticated) return;

    try {
      // ✅ webview_windows uses executeScript
      final cookies = await _controller!.executeScript('document.cookie');
      if (cookies != null && cookies.isNotEmpty && cookies.contains('_forward_auth_csrf')) {
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
      } else {
        _startPeriodicCheck();
      }
    } catch (e) {
      if (kDebugMode) print('Error extracting cookies: $e');
      _startPeriodicCheck();
    }
  }

  void _startPeriodicCheck() {
    Future.delayed(const Duration(seconds: 3), () {
      if (mounted && !_isAuthenticated) {
        _checkCookies();
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Loading…'),
        automaticallyImplyLeading: false,
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : _controller != null
              ? Webview(_controller!)
              : Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const Text('Failed to initialize WebView.'),
                      const SizedBox(height: 16),
                      ElevatedButton(
                        onPressed: _initWebView,
                        child: const Text('Retry'),
                      ),
                    ],
                  ),
                ),
    );
  }
}