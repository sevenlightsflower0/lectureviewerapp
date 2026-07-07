import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show kIsWeb, defaultTargetPlatform;
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:http/http.dart' as http;
import '../models/transcript_message.dart';

class LiveTranscriptScreen extends StatefulWidget {
  final String initialUrl;
  const LiveTranscriptScreen({super.key, required this.initialUrl});

  @override
  State<LiveTranscriptScreen> createState() => _LiveTranscriptScreenState();
}

class _LiveTranscriptScreenState extends State<LiveTranscriptScreen> {
  WebSocketChannel? _channel;
  StreamSubscription? _sseSubscription;
  bool _isConnected = false;
  String? _errorMessage;
  bool _isConnecting = false;

  // TTS
  final FlutterTts _flutterTts = FlutterTts();
  bool _ttsEnabled = true;

  // Firestore
  CollectionReference? _transcriptsRef;
  String _sessionId = '';

  // UI state
  TranscriptMessage? _latestMessage;

  bool get _isDesktop {
    if (kIsWeb) return false;
    switch (defaultTargetPlatform) {
      case TargetPlatform.windows:
      case TargetPlatform.macOS:
      case TargetPlatform.linux:
        return true;
      default:
        return false;
    }
  }

  @override
  void initState() {
    super.initState();
    _initTts();
    _initFirebaseAndSession();
  }

  Future<void> _initTts() async {
    await _flutterTts.setLanguage("en-US");
    await _flutterTts.setSpeechRate(0.5);
    await _flutterTts.setPitch(1.0);
  }

  Future<void> _initFirebaseAndSession() async {
    try {
      final user = FirebaseAuth.instance.currentUser;
      if (user == null) {
        await FirebaseAuth.instance.signInAnonymously();
      }
      final currentUser = FirebaseAuth.instance.currentUser;
      if (currentUser != null) {
        final prefs = await SharedPreferences.getInstance();
        _sessionId = prefs.getString('session_id_${widget.initialUrl}') ??
            DateTime.now().millisecondsSinceEpoch.toString();
        await prefs.setString('session_id_${widget.initialUrl}', _sessionId);
        _transcriptsRef = FirebaseFirestore.instance
            .collection('users')
            .doc(currentUser.uid)
            .collection('sessions')
            .doc(_sessionId)
            .collection('transcripts');
      }
    } catch (e) {
      if (_isDesktop) {
        debugPrint('⚠️ Firebase not configured on desktop. Continuing without it.');
      } else {
        debugPrint('Firebase error: $e');
        setState(() => _errorMessage = 'Firebase error: $e (will still try to connect)');
      }
      _sessionId = 'temp_${DateTime.now().millisecondsSinceEpoch}';
    }
    _connect(widget.initialUrl);
  }

  // ─── Connection dispatcher ───────────────────────────────
  void _connect(String url) {
    setState(() {
      _errorMessage = null;
      _isConnected = false;
      _isConnecting = true;
    });

    // SSE uses HTTP/HTTPS
    if (url.startsWith('http://') || url.startsWith('https://')) {
      _connectSSE(url);
    } else {
      _connectWebSocket(url);
    }
  }

  // ─── Manual SSE client ───────────────────────────────────
  void _connectSSE(String url) {
    debugPrint('🔗 Connecting to SSE: $url');

    final headers = {
      'Accept': 'text/event-stream',
      'Cache-Control': 'no-cache',
      'Connection': 'keep-alive',
    };

    http.Client().send(http.Request('GET', Uri.parse(url))
      ..headers.addAll(headers)
    ).then((response) {
      if (response.statusCode != 200) {
        throw Exception('Server returned HTTP ${response.statusCode}');
      }
      final stream = response.stream.transform(utf8.decoder);

      String buffer = '';
      StreamSubscription<String> subscription;
      subscription = stream.listen((String chunk) {
        buffer += chunk;
        final events = buffer.split('\n\n');
        if (events.length > 1) {
          buffer = events.removeLast();
          for (final eventBlock in events) {
            _parseSSEEvent(eventBlock);
          }
        }
      }, onError: (error) {
        debugPrint('❌ SSE stream error: $error');
        setState(() {
          _errorMessage = 'SSE error: $error';
          _isConnected = false;
          _isConnecting = false;
        });
      }, onDone: () {
        debugPrint('🔌 SSE disconnected');
        setState(() {
          _isConnected = false;
          _isConnecting = false;
        });
      });
      _sseSubscription = subscription;

      setState(() {
        _isConnected = true;
        _isConnecting = false;
      });
    }).catchError((error) {
      debugPrint('❌ Failed to connect SSE: $error');
      setState(() {
        _errorMessage = 'Failed to connect: $error';
        _isConnected = false;
        _isConnecting = false;
      });
    });
  }

  void _parseSSEEvent(String eventBlock) {
    final lines = eventBlock.split('\n');
    StringBuffer dataBuffer = StringBuffer();

    for (final line in lines) {
      if (line.startsWith('data:')) {
        dataBuffer.writeln(line.substring(5).trim());
      }
      // We ignore 'event:' lines for now; they aren't needed.
    }

    final data = dataBuffer.toString().trim();
    if (data.isEmpty) return;

    try {
      final json = jsonDecode(data);
      _handleMessage(json);
    } catch (e) {
      debugPrint('⚠️ Failed to parse SSE data: $e');
    }
  }

  // ─── WebSocket connection (fallback) ────────────────────
  void _connectWebSocket(String url) {
    debugPrint('🔗 Connecting to WebSocket: $url');

    try {
      _channel = WebSocketChannel.connect(Uri.parse(url));
      _channel!.stream.listen(
        (data) async {
          try {
            final Map<String, dynamic> json =
                data is String ? jsonDecode(data) : data as Map<String, dynamic>;
            await _handleMessage(json);
          } catch (e) {
            debugPrint('⚠️ WebSocket parse error: $e');
          }
        },
        onError: (error) {
          debugPrint('❌ WebSocket error: $error');
          setState(() {
            _errorMessage = 'WebSocket error: $error';
            _isConnected = false;
            _isConnecting = false;
          });
        },
        onDone: () {
          debugPrint('🔌 WebSocket disconnected');
          setState(() {
            _isConnected = false;
            _isConnecting = false;
          });
        },
      );
    } catch (e) {
      debugPrint('❌ Failed to connect WebSocket: $e');
      setState(() {
        _errorMessage = 'Failed to connect: $e';
        _isConnected = false;
        _isConnecting = false;
      });
    }
  }

  // ─── Shared message handler ─────────────────────────────
  Future<void> _handleMessage(Map<String, dynamic> json) async {
    TranscriptMessage message;
    try {
      message = TranscriptMessage.fromJson(json);
    } catch (e) {
      message = TranscriptMessage(
        transcript: json.toString(),
        translations: {},
        timestamp: DateTime.now(),
      );
    }

    if (_transcriptsRef != null) {
      try {
        await _transcriptsRef!.add({
          'transcript': message.transcript,
          'translations': message.translations,
          'timestamp': Timestamp.fromDate(message.timestamp),
        });
      } catch (e) {
        debugPrint('⚠️ Could not save to Firestore: $e');
      }
    }

    setState(() {
      _latestMessage = message;
      _isConnected = true;
      _isConnecting = false;
    });

    if (_ttsEnabled && message.transcript.isNotEmpty) {
      await _flutterTts.speak(message.transcript);
    }
  }

  void _reconnect() {
    _channel?.sink.close();
    _sseSubscription?.cancel();
    _sseSubscription = null;
    _connect(widget.initialUrl);
  }

  Future<void> _toggleTts() async {
    setState(() => _ttsEnabled = !_ttsEnabled);
    if (!_ttsEnabled) {
      await _flutterTts.stop();
    }
  }

  Future<void> _scanNewQR() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('session_url');
    await prefs.remove('session_id_${widget.initialUrl}');
    _channel?.sink.close();
    _sseSubscription?.cancel();
    _sseSubscription = null;
    await _flutterTts.stop();
    if (mounted) {
      Navigator.pushReplacementNamed(context, '/scan');
    }
  }

  @override
  void dispose() {
    _channel?.sink.close();
    _sseSubscription?.cancel();
    _sseSubscription = null;
    _flutterTts.stop();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Live Transcript'),
        actions: [
          IconButton(
            icon: Icon(_ttsEnabled ? Icons.volume_up : Icons.volume_off),
            onPressed: _toggleTts,
            tooltip: 'Toggle TTS',
          ),
          IconButton(
            icon: const Icon(Icons.qr_code_scanner),
            onPressed: _scanNewQR,
            tooltip: 'Scan new QR',
          ),
        ],
      ),
      body: Column(
        children: [
          Container(
            padding: const EdgeInsets.all(8),
            color: _isConnected ? Colors.green.shade100 : Colors.red.shade100,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(
                  _isConnected ? Icons.wifi : (_isConnecting ? Icons.wifi_lock : Icons.wifi_off),
                  color: _isConnected ? Colors.green : (_isConnecting ? Colors.orange : Colors.red),
                ),
                const SizedBox(width: 8),
                Text(_isConnected ? 'Live connection' : (_isConnecting ? 'Connecting...' : 'Disconnected')),
                if (_errorMessage != null) ...[
                  const SizedBox(width: 16),
                  Expanded(
                    child: Text(
                      _errorMessage!,
                      style: const TextStyle(color: Colors.red),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
                if (!_isConnected && !_isConnecting) ...[
                  const SizedBox(width: 16),
                  TextButton(
                    onPressed: _reconnect,
                    child: const Text('Retry'),
                  ),
                ],
              ],
            ),
          ),
          Expanded(
            child: Center(
              child: _latestMessage == null
                  ? const Text('Waiting for transcript...')
                  : SingleChildScrollView(
                      padding: const EdgeInsets.all(24),
                      child: Card(
                        elevation: 4,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(20),
                        ),
                        child: Padding(
                          padding: const EdgeInsets.all(24),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  const Icon(Icons.record_voice_over, size: 28),
                                  const SizedBox(width: 12),
                                  Expanded(
                                    child: Text(
                                      _latestMessage!.transcript,
                                      style: const TextStyle(
                                        fontSize: 24,
                                        fontWeight: FontWeight.bold,
                                      ),
                                    ),
                                  ),
                                  Text(
                                    '${_latestMessage!.timestamp.hour.toString().padLeft(2, '0')}:${_latestMessage!.timestamp.minute.toString().padLeft(2, '0')}:${_latestMessage!.timestamp.second.toString().padLeft(2, '0')}',
                                    style: const TextStyle(fontSize: 12),
                                  ),
                                ],
                              ),
                              if (_latestMessage!.translations.isNotEmpty) ...[
                                const Divider(height: 32),
                                Wrap(
                                  spacing: 16,
                                  runSpacing: 12,
                                  children: _latestMessage!.translations.entries
                                      .map((entry) => Column(
                                            crossAxisAlignment: CrossAxisAlignment.start,
                                            children: [
                                              Text(
                                                entry.key.toUpperCase(),
                                                style: const TextStyle(
                                                  fontWeight: FontWeight.bold,
                                                  fontSize: 14,
                                                ),
                                              ),
                                              const SizedBox(height: 4),
                                              Text(
                                                entry.value,
                                                style: const TextStyle(fontSize: 16),
                                              ),
                                            ],
                                          ))
                                      .toList(),
                                ),
                              ],
                            ],
                          ),
                        ),
                      ),
                    ),
            ),
          ),
        ],
      ),
    );
  }
}