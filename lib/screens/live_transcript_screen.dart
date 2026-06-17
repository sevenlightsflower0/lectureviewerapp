import 'package:flutter/material.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_tts/flutter_tts.dart';
import '../models/transcript_message.dart';

class LiveTranscriptScreen extends StatefulWidget {
  final String initialUrl;
  const LiveTranscriptScreen({super.key, required this.initialUrl});

  @override
  State<LiveTranscriptScreen> createState() => _LiveTranscriptScreenState();
}

class _LiveTranscriptScreenState extends State<LiveTranscriptScreen> {
  late WebSocketChannel _channel;
  TranscriptMessage? _latestMessage;
  bool _isConnected = false;
  String? _errorMessage;

  // TTS
  final FlutterTts _flutterTts = FlutterTts();
  bool _ttsEnabled = true;

  // Firestore (for optional history storage, but not used in UI)
  late String _sessionId;
  late CollectionReference _transcriptsRef;

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
    // Anonymous auth
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      await FirebaseAuth.instance.signInAnonymously();
    }

    // Session ID based on URL
    final prefs = await SharedPreferences.getInstance();
    _sessionId = prefs.getString('session_id_${widget.initialUrl}') ??
        DateTime.now().millisecondsSinceEpoch.toString();
    await prefs.setString('session_id_${widget.initialUrl}', _sessionId);

    _transcriptsRef = FirebaseFirestore.instance
        .collection('users')
        .doc(FirebaseAuth.instance.currentUser!.uid)
        .collection('sessions')
        .doc(_sessionId)
        .collection('transcripts');

    // No loading of previous transcripts – we only show the latest.
    _connect(widget.initialUrl);
  }

  void _connect(String url) {
    setState(() {
      _errorMessage = null;
      _isConnected = false;
    });
    try {
      _channel = WebSocketChannel.connect(Uri.parse(url));
      _channel.stream.listen(
        (data) async {
          TranscriptMessage message;
          try {
            final Map<String, dynamic> json =
                data is String ? jsonDecode(data) : data as Map<String, dynamic>;
            message = TranscriptMessage.fromJson(json);
          } catch (e) {
            // Fallback for raw string
            message = TranscriptMessage(
              transcript: data.toString(),
              translations: {},
              timestamp: DateTime.now(),
            );
          }

          // Save to Firestore (optional, can be disabled)
          await _transcriptsRef.add({
            'transcript': message.transcript,
            'translations': message.translations,
            'timestamp': Timestamp.fromDate(message.timestamp),
          });

          // Update UI with latest message
          setState(() {
            _latestMessage = message;
            _isConnected = true;
          });

          // Text-to-Speech for the new transcript
          if (_ttsEnabled && message.transcript.isNotEmpty) {
            await _flutterTts.speak(message.transcript);
          }
        },
        onError: (error) {
          setState(() {
            _errorMessage = 'WebSocket error: $error';
            _isConnected = false;
          });
        },
        onDone: () {
          setState(() => _isConnected = false);
        },
      );
    } catch (e) {
      setState(() {
        _errorMessage = 'Failed to connect: $e';
        _isConnected = false;
      });
    }
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
    _channel.sink.close();
    await _flutterTts.stop();
    if (mounted) {
      Navigator.pushReplacementNamed(context, '/scan');
    }
  }

  @override
  void dispose() {
    _channel.sink.close();
    _flutterTts.stop();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Live Transcript (latest only)'),
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
          // Connection status bar
          Container(
            padding: const EdgeInsets.all(8),
            color: _isConnected ? Colors.green.shade100 : Colors.red.shade100,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(
                  _isConnected ? Icons.wifi : Icons.wifi_off,
                  color: _isConnected ? Colors.green : Colors.red,
                ),
                const SizedBox(width: 8),
                Text(_isConnected ? 'Live connection' : 'Disconnected'),
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
              ],
            ),
          ),
          // Latest transcript display
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
                                  const Icon(Icons.record_voice_over,
                                      size: 28),
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
                                            crossAxisAlignment:
                                                CrossAxisAlignment.start,
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
                                                style: const TextStyle(
                                                    fontSize: 16),
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