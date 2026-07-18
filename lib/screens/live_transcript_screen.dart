import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show kIsWeb, defaultTargetPlatform, kDebugMode;
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:http/http.dart' as http;
import 'package:audioplayers/audioplayers.dart';
import '../models/transcript_message.dart';

class LiveTranscriptScreen extends StatefulWidget {
  final String resolvedUrl;
  final String? originalUrl;

  const LiveTranscriptScreen({
    super.key,
    required this.resolvedUrl,
    this.originalUrl,
  });

  @override
  State<LiveTranscriptScreen> createState() => _LiveTranscriptScreenState();
}

class _LiveTranscriptScreenState extends State<LiveTranscriptScreen> {
  String? _selectedLanguage;
  final Set<String> _availableLanguages = {};
  final Map<String, TranscriptMessage> _messagesMap = {};
  bool _defaultFilterSet = false;

  Map<String, String>? _senderToLanguage;

  WebSocketChannel? _channel;
  StreamSubscription? _sseSubscription;
  bool _isConnected = false;
  String? _errorMessage;
  bool _isConnecting = false;

  CollectionReference? _transcriptsRef;
  String _sessionId = '';

  // Scroll controller for auto‑scroll
  final ScrollController _scrollController = ScrollController();

  // Audio player and playback state
  final AudioPlayer _audioPlayer = AudioPlayer();
  String? _playingKey;               // key of the message currently playing
  bool _isAudioPlaying = false;
  final Map<String, double> _progressMap = {};   // key → progress (0.0–1.0)
  final Map<String, Duration> _durationMap = {}; // key → total duration

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
    if (kDebugMode) {
      print('🔗 SSE URL: ${widget.resolvedUrl}');
    }
    _initFirebaseAndSession();
    _setupAudioListeners();
  }

  void _setupAudioListeners() {
    _audioPlayer.onPositionChanged.listen((Duration position) {
      if (_playingKey != null) {
        final duration = _durationMap[_playingKey];
        if (duration != null && duration.inMilliseconds > 0) {
          setState(() {
            _progressMap[_playingKey!] = position.inMilliseconds / duration.inMilliseconds;
          });
        }
      }
    });

    _audioPlayer.onDurationChanged.listen((Duration duration) {
      if (_playingKey != null) {
        setState(() {
          _durationMap[_playingKey!] = duration;
        });
      }
    });

    _audioPlayer.onPlayerComplete.listen((_) {
      setState(() {
        if (_playingKey != null) {
          _progressMap[_playingKey!] = 1.0;
        }
        _playingKey = null;
        _isAudioPlaying = false;
      });
    });

    // audioplayers no longer exposes onPlayerError in newer versions.
    // Use onPlayerStateChanged to track playing state and handle failures if needed.
    _audioPlayer.onPlayerStateChanged.listen((PlayerState state) {
      setState(() {
        _isAudioPlaying = state == PlayerState.playing;
        if (state == PlayerState.completed || state == PlayerState.stopped) {
          _playingKey = null;
        }
      });
    });
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
        _sessionId = prefs.getString('session_id_${widget.resolvedUrl}') ??
            DateTime.now().millisecondsSinceEpoch.toString();
        await prefs.setString('session_id_${widget.resolvedUrl}', _sessionId);
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

    await _fetchLanguageMapping();
    _connect(widget.resolvedUrl);
  }

  Future<void> _fetchLanguageMapping() async {
    if (widget.originalUrl == null ||
        !widget.originalUrl!.startsWith('http')) {
      return;
    }

    try {
      final response = await http.get(Uri.parse(widget.originalUrl!));
      if (response.statusCode != 200) {
        return;
      }

      final body = response.body;

      final senderRegex = RegExp(r'data-sender="([^"]+)"');
      final senderMatch = senderRegex.firstMatch(body);
      if (senderMatch != null) {
        final raw = senderMatch.group(1)!.replaceAll('&quot;', '"');
        final Map<String, dynamic> map = jsonDecode(raw);
        _senderToLanguage = map.map((k, v) => MapEntry(k, v.toString()));
      }

      final langNameRegex = RegExp(r'data-lang-name="([^"]+)"');
      final langNameMatch = langNameRegex.firstMatch(body);
      if (langNameMatch != null) {
        final raw = langNameMatch.group(1)!.replaceAll('&quot;', '"');
        final Map<String, dynamic> map = jsonDecode(raw);
        for (final entry in map.entries) {
          final name = entry.value.toString();
          if (!name.contains('Audio') && !name.contains('Correction')) {
            _availableLanguages.add(name);
          }
        }

        if (!_defaultFilterSet && _availableLanguages.isNotEmpty) {
          _selectedLanguage = _availableLanguages.contains('Transcript')
              ? 'Transcript'
              : _availableLanguages.first;
          _defaultFilterSet = true;
        }
      }
    } catch (e) {
      debugPrint('Could not fetch language mapping: $e');
    }
  }

  void _connect(String url) {
    setState(() {
      _errorMessage = null;
      _isConnected = false;
      _isConnecting = true;
      _messagesMap.clear();
      _defaultFilterSet = false;
      _selectedLanguage = null;
      _playingKey = null;
      _isAudioPlaying = false;
      _progressMap.clear();
      _durationMap.clear();
    });

    if (url.startsWith('http://') || url.startsWith('https://')) {
      _connectSSE(url);
    } else {
      _connectWebSocket(url);
    }
  }

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
    debugPrint('📦 Full SSE event block:\n$eventBlock');
    final lines = eventBlock.split('\n');
    StringBuffer dataBuffer = StringBuffer();

    for (final line in lines) {
      if (line.startsWith('data:')) {
        dataBuffer.writeln(line.substring(5).trim());
      }
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

  String _extractLanguageFromSender(String sender) {
    if (_senderToLanguage != null && _senderToLanguage!.containsKey(sender)) {
      return _senderToLanguage![sender]!;
    }
    return sender;
  }

  String _cleanTranscript(String raw) {
    return raw.replaceAll(RegExp(r'<[^>]*>'), ' ');
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOut,
        );
      }
    });
  }

  Future<void> _handleMessage(Map<String, dynamic> json) async {
    debugPrint('📩 JSON keys: ${json.keys}');
    debugPrint('🔍 sender: "${json['sender']}"');

    String transcriptText = (json['text'] ?? json['seq'] ?? '').toString().trim();
    transcriptText = _cleanTranscript(transcriptText);

    if (transcriptText.isEmpty) {
      debugPrint('⏭️ Skipping message with empty text/seq');
      return;
    }

    final sender = json['sender'] ?? '';
    final language = _extractLanguageFromSender(sender);

    if (!language.contains('Audio') && !language.contains('Correction')) {
      _availableLanguages.add(language);
    }

    if (!_defaultFilterSet && !language.contains('Audio') && !language.contains('Correction')) {
      _selectedLanguage = language;
      _defaultFilterSet = true;
    }

    final isUnstable = json['unstable'] == true;
    final start = json['start']?.toString() ?? '';

    String key;
    if (start.isNotEmpty) {
      key = '$sender|$start';
    } else {
      final textPrefix = transcriptText.length > 20
          ? transcriptText.substring(0, 20)
          : transcriptText;
      key = '$sender|$textPrefix';
    }

    // Extract audio data if present
    Uint8List? audioBytes;
    final audioBase64 = json['audio'] as String?;
    if (audioBase64 != null) {
      try {
        audioBytes = base64Decode(audioBase64);
      } catch (e) {
        debugPrint('Failed to decode audio: $e');
      }
    }

    _messagesMap[key] = TranscriptMessage(
      transcript: transcriptText,
      translations: {},
      timestamp: DateTime.now(),
      language: language,
      isUnstable: isUnstable,
      audioData: audioBytes,
    );

    if (_transcriptsRef != null) {
      try {
        await _transcriptsRef!.add({
          'transcript': transcriptText,
          'translations': {},
          'timestamp': Timestamp.fromDate(DateTime.now()),
          'language': language,
          'isUnstable': isUnstable,
          // optionally store audio? (might be large – skip or handle separately)
        });
      } catch (e) {
        debugPrint('⚠️ Could not save to Firestore: $e');
      }
    }

    setState(() {
      _isConnected = true;
      _isConnecting = false;
    });
    _scrollToBottom();
  }

  void _reconnect() {
    _channel?.sink.close();
    _sseSubscription?.cancel();
    _sseSubscription = null;
    _connect(widget.resolvedUrl);
  }

  Future<void> _playPause(String key, Uint8List audioData) async {
    if (_playingKey == key) {
      if (_isAudioPlaying) {
        await _audioPlayer.pause();
        setState(() => _isAudioPlaying = false);
      } else {
        await _audioPlayer.resume();
        setState(() => _isAudioPlaying = true);
      }
    } else {
      // Stop any current playback
      await _audioPlayer.stop();
      setState(() {
        // Reset progress for previous key (optional)
        _playingKey = null;
        _isAudioPlaying = false;
      });

      try {
        await _audioPlayer.setSourceBytes(audioData);
        await _audioPlayer.resume();
        setState(() {
          _playingKey = key;
          _isAudioPlaying = true;
          _progressMap[key] = 0.0;
        });
      } catch (e) {
        debugPrint('Error playing audio: $e');
        // Optionally show a snackbar
      }
    }
  }

  Future<void> _scanNewQR() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('session_url');
    await prefs.remove('session_id_${widget.resolvedUrl}');
    _channel?.sink.close();
    _sseSubscription?.cancel();
    _sseSubscription = null;
    await _audioPlayer.stop();
    if (mounted) {
      Navigator.pushReplacementNamed(context, '/scan');
    }
  }

  @override
  void dispose() {
    _channel?.sink.close();
    _sseSubscription?.cancel();
    _sseSubscription = null;
    _audioPlayer.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Get sorted keys by timestamp
    final sortedKeys = _messagesMap.keys.toList()
      ..sort((a, b) => _messagesMap[a]!.timestamp.compareTo(_messagesMap[b]!.timestamp));

    // Filter by selected language
    final filteredKeys = sortedKeys.where((key) {
      final msg = _messagesMap[key]!;
      return _selectedLanguage == null ||
          msg.language.toLowerCase() == _selectedLanguage!.toLowerCase();
    }).toList();

    return Scaffold(
      appBar: AppBar(
        title: const Text('Live Transcript'),
        actions: [
          if (_availableLanguages.isNotEmpty)
            DropdownButton<String>(
              value: _selectedLanguage,
              hint: const Text('All'),
              items: [
                const DropdownMenuItem<String>(
                  value: null,
                  child: Text('All (transcript)'),
                ),
                ..._availableLanguages.map((lang) {
                  return DropdownMenuItem<String>(
                    value: lang,
                    child: Text(lang),
                  );
                }),
              ],
              onChanged: (newLang) {
                setState(() {
                  _selectedLanguage = newLang;
                });
              },
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
          // Status bar (unchanged)
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
                if (_selectedLanguage != null) ...[
                  const SizedBox(width: 12),
                  Chip(
                    label: Text('Filter: $_selectedLanguage'),
                    backgroundColor: Colors.blue.shade100,
                    deleteIcon: const Icon(Icons.close, size: 16),
                    onDeleted: () {
                      setState(() {
                        _selectedLanguage = null;
                      });
                    },
                  ),
                ],
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
          // List of message cards
          Expanded(
            child: filteredKeys.isEmpty
                ? Center(
                    child: Text(
                      _messagesMap.isEmpty
                          ? 'Waiting for transcript...'
                          : 'No messages in $_selectedLanguage',
                    ),
                  )
                : ListView.builder(
                    controller: _scrollController,
                    itemCount: filteredKeys.length,
                    itemBuilder: (context, index) {
                      final key = filteredKeys[index];
                      final message = _messagesMap[key]!;
                      final hasAudio = message.audioData != null;

                      return Card(
                        margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                        child: Padding(
                          padding: const EdgeInsets.all(12),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                message.transcript,
                                style: TextStyle(
                                  fontSize: 16,
                                  color: message.isUnstable ? Colors.grey : Colors.black,
                                ),
                              ),
                              if (hasAudio) ...[
                                const SizedBox(height: 8),
                                Row(
                                  children: [
                                    IconButton(
                                      icon: Icon(
                                        _playingKey == key && _isAudioPlaying
                                            ? Icons.pause
                                            : Icons.play_arrow,
                                      ),
                                      onPressed: () => _playPause(key, message.audioData!),
                                    ),
                                    Expanded(
                                      child: LinearProgressIndicator(
                                        value: _progressMap[key] ?? 0.0,
                                        backgroundColor: Colors.grey[300],
                                      ),
                                    ),
                                    const SizedBox(width: 8),
                                    Text(
                                      _durationMap[key] != null
                                          ? '${_durationMap[key]!.inSeconds}s'
                                          : '',
                                      style: const TextStyle(fontSize: 12),
                                    ),
                                  ],
                                ),
                              ],
                            ],
                          ),
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}