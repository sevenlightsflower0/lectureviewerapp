// ignore_for_file: use_build_context_synchronously

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show kIsWeb, defaultTargetPlatform;
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:http/http.dart' as http;
import 'dart:developer' as developer;

class QRScannerScreen extends StatefulWidget {
  const QRScannerScreen({super.key});

  @override
  State<QRScannerScreen> createState() => _QRScannerScreenState();
}

class _QRScannerScreenState extends State<QRScannerScreen> {
  bool get _cameraSupported {
    if (kIsWeb) return true;
    switch (defaultTargetPlatform) {
      case TargetPlatform.android:
      case TargetPlatform.iOS:
        return true;
      case TargetPlatform.windows:
      case TargetPlatform.macOS:
      case TargetPlatform.linux:
        return false;
      default:
        return false;
    }
  }

  late final MobileScannerController? scannerController =
      _cameraSupported ? MobileScannerController() : null;

  bool _isProcessing = false;

  @override
  void dispose() {
    scannerController?.dispose();
    super.dispose();
  }

  // ─── URL resolver: fetches session ID and builds SSE URL ──────────
  Future<String> _resolveUrl(String input) async {
    input = input.trim();

    // 1. Already a WebSocket URL? (backward compatibility)
    if (input.startsWith('ws://') || input.startsWith('wss://')) {
      return input;
    }

    // 2. Must be an HTTP(S) URL to fetch.
    if (!input.startsWith('http://') && !input.startsWith('https://')) {
      throw Exception(
          'Invalid URL format. Please enter a ws://, wss://, http://, or https:// URL.');
    }

    // 3. Fetch the HTML.
    final response = await http.get(Uri.parse(input));
    if (response.statusCode != 200) {
      throw Exception('Server returned HTTP ${response.statusCode}');
    }

    String body = response.body;

    // Debug: print first 500 chars.
    developer.log('Raw response (first 500 chars): ${body.substring(0, body.length > 500 ? 500 : body.length)}');

    // 4. Extract session ID from window.sessionId = "...";
    final sessionIdRegex = RegExp(r'window\.sessionId\s*=\s*"([^"]+)"');
    final match = sessionIdRegex.firstMatch(body);
    if (match == null) {
      throw Exception('Could not find window.sessionId in the page.');
    }
    final sessionId = match.group(1)!;
    developer.log('Extracted session ID: $sessionId');

    // 5. Build the SSE (EventSource) URL – HTTP/HTTPS
    final uri = Uri.parse(input);
    final host = uri.host;
    final scheme = uri.scheme; // https
    final sseUrl = '$scheme://$host/webapi/stream?channel=$sessionId';
    developer.log('Constructed SSE URL: $sseUrl');
    return sseUrl;
  }

  // ─── History helper ───────────────────────────────────────────────
  Future<void> _addToHistory(String url) async {
    final prefs = await SharedPreferences.getInstance();
    List<String> history = prefs.getStringList('session_history') ?? [];
    history.remove(url);
    history.insert(0, url);
    if (history.length > 20) history = history.sublist(0, 20);
    await prefs.setStringList('session_history', history);
  }

  Future<void> _proceedWithUrl(String rawInput) async {
    if (rawInput.trim().isEmpty) return;

    setState(() => _isProcessing = true);

    if (scannerController != null) {
      await scannerController!.stop();
    }

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => const Center(child: CircularProgressIndicator()),
    );

    String websocketUrl = '';

    try {
      websocketUrl = await _resolveUrl(rawInput);
      await _addToHistory(websocketUrl);

      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('session_url', websocketUrl);

      if (mounted) {
        Navigator.pop(context);
        Navigator.pushReplacementNamed(
          context,
          '/live',
          arguments: websocketUrl,
        );
      }
    } catch (e) {
      if (mounted) {
        Navigator.pop(context);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error: $e'),
            backgroundColor: Colors.red,
          ),
        );
        await scannerController?.start();
        setState(() => _isProcessing = false);
      }
    }
  }

  // ─── UI builders ──────────────────────────────────────────────────
  Widget _buildManualEntryScreen() {
    final TextEditingController textController = TextEditingController();

    return Padding(
      padding: const EdgeInsets.all(24.0),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(Icons.link, size: 80, color: Colors.blue),
          const SizedBox(height: 24),
          const Text(
            'Enter the WebSocket URL manually',
            style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 16),
          const Text(
            'Camera is not available on this platform.\nPaste or type the URL below.',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 14, color: Colors.grey),
          ),
          const SizedBox(height: 32),
          TextField(
            controller: textController,
            decoration: const InputDecoration(
              hintText: 'wss://example.com/ws  or  https://.../shorten/...',
              border: OutlineInputBorder(),
              prefixIcon: Icon(Icons.link),
            ),
            autofocus: true,
            keyboardType: TextInputType.url,
          ),
          const SizedBox(height: 24),
          ElevatedButton.icon(
            onPressed: () {
              final url = textController.text.trim();
              if (url.isNotEmpty) {
                _proceedWithUrl(url);
              }
            },
            icon: const Icon(Icons.arrow_forward),
            label: const Text('Connect'),
            style: ElevatedButton.styleFrom(
              minimumSize: const Size(double.infinity, 50),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildScannerUI() {
    return Stack(
      children: [
        MobileScanner(
          controller: scannerController!,
          onDetect: _onScanComplete,
        ),
        const Align(
          alignment: Alignment.bottomCenter,
          child: Padding(
            padding: EdgeInsets.all(24),
            child: Text(
              'Point camera at QR code or tap ✏️ to enter URL manually',
              style: TextStyle(
                color: Colors.white,
                backgroundColor: Colors.black54,
              ),
              textAlign: TextAlign.center,
            ),
          ),
        ),
      ],
    );
  }

  Future<void> _onScanComplete(BarcodeCapture capture) async {
    if (_isProcessing) return;
    final String? rawValue = capture.barcodes.first.rawValue;
    if (rawValue == null) return;
    await _proceedWithUrl(rawValue);
  }

  void _showManualEntryDialog() {
    final TextEditingController textController = TextEditingController();

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        title: const Text('Enter WebSocket or HTTPS URL'),
        content: TextField(
          controller: textController,
          decoration: const InputDecoration(
            hintText: 'wss://example.com/ws  or  https://.../shorten/...',
            border: OutlineInputBorder(),
          ),
          autofocus: true,
          keyboardType: TextInputType.url,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () {
              final url = textController.text.trim();
              if (url.isNotEmpty) {
                Navigator.pop(context);
                _proceedWithUrl(url);
              }
            },
            child: const Text('Connect'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final bool useCamera = _cameraSupported;

    return Scaffold(
      appBar: AppBar(
        title: Text(useCamera ? 'Scan QR Code' : 'Enter URL'),
      ),
      body: useCamera
          ? _buildScannerUI()
          : _buildManualEntryScreen(),
      floatingActionButton: useCamera
          ? FloatingActionButton.extended(
              onPressed: _showManualEntryDialog,
              icon: const Icon(Icons.edit),
              label: const Text('Enter URL manually'),
            )
          : null,
    );
  }
}