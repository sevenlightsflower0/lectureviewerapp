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
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
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

  final ScrollController _scrollController = ScrollController();

  final AudioPlayer _audioPlayer = AudioPlayer();
  String? _playingKey;
  bool _isAudioPlaying = false;
  final Map<String, double> _progressMap = {};
  final Map<String, Duration> _durationMap = {};

  final http.Client _httpClient = http.Client();
  final FlutterSecureStorage _secureStorage = const FlutterSecureStorage();

  // Store session ID from SSE events
  String? _sseSessionId;
  String? _baseUrl;

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
    _checkAuth(); // new method
    if (kDebugMode) {
      print('🔗 SSE URL: ${widget.resolvedUrl}');
    }
    _baseUrl = widget.originalUrl != null
        ? Uri.parse(widget.originalUrl!).origin
        : Uri.parse(widget.resolvedUrl).origin;
    debugPrint('🏠 Base URL: $_baseUrl');

    _initFirebaseAndSession();
    _setupAudioListeners();
  }

  Future<void> _checkAuth() async {
    final cookies = await _secureStorage.read(key: 'cookies');
    if (cookies == null || cookies.isEmpty) {
      // No cookies, navigate to auth screen
      if (mounted && widget.originalUrl != null) {
        Navigator.pushReplacementNamed(
          context,
          '/auth',
          arguments: {
            'originalUrl': widget.originalUrl!,
            'resolvedUrl': widget.resolvedUrl,
          },
        );
      }
    }
  }

  void _setupAudioListeners() {
    _audioPlayer.onPositionChanged.listen((Duration position) {
      if (!mounted) return;
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
      if (!mounted) return;
      if (_playingKey != null) {
        setState(() {
          _durationMap[_playingKey!] = duration;
        });
      }
    });

    _audioPlayer.onPlayerComplete.listen((_) {
      if (!mounted) return;
      setState(() {
        if (_playingKey != null) {
          _progressMap[_playingKey!] = 1.0;
        }
        _playingKey = null;
        _isAudioPlaying = false;
      });
    });

    _audioPlayer.onPlayerStateChanged.listen((PlayerState state) {
      if (!mounted) return;
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
        if (mounted) setState(() => _errorMessage = 'Firebase error: $e (will still try to connect)');
      }
      _sessionId = 'temp_${DateTime.now().millisecondsSinceEpoch}';
    }

    await _fetchLanguageMapping();
    _connect(widget.resolvedUrl);
  }

  Future<void> _fetchLanguageMapping() async {
    if (widget.originalUrl == null || !widget.originalUrl!.startsWith('http')) return;

    try {
      final response = await _httpClient.get(
        Uri.parse(widget.originalUrl!),
        headers: _browserHeaders(),
      );
      if (response.statusCode != 200) return;
      final setCookie = response.headers['set-cookie'];
      if (setCookie != null && setCookie.isNotEmpty) {
        await _secureStorage.write(key: 'cookies', value: setCookie);
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
          if (mounted) {
            setState(() {
              _selectedLanguage = _availableLanguages.contains('Transcript')
                  ? 'Transcript'
                  : _availableLanguages.first;
              _defaultFilterSet = true;
            });
          }
        }
      }
    } catch (e) {
      debugPrint('Could not fetch language mapping: $e');
    }
  }

  Map<String, String> _browserHeaders() {
    return {
      'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/91.0.4472.124 Safari/537.36',
      'Accept': 'text/html,application/xhtml+xml,application/xml;q=0.9,image/webp,*/*;q=0.8',
      'Accept-Language': 'en-US,en;q=0.5',
      'Accept-Encoding': 'gzip, deflate, br',
      'Connection': 'keep-alive',
      'Upgrade-Insecure-Requests': '1',
    };
  }

  void _connect(String url) {
    if (!mounted) return;
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
      _sseSessionId = null;
    });

    if (url.startsWith('http://') || url.startsWith('https://')) {
      _connectSSE(url);
    } else {
      _connectWebSocket(url);
    }
  }

  void _reconnect() {
    _channel?.sink.close();
    _sseSubscription?.cancel();
    _sseSubscription = null;
    _connect(widget.resolvedUrl);
  }

  void _connectSSE(String url) {
    debugPrint('🔗 Connecting to SSE: $url');

    final headers = {
      'Accept': 'text/event-stream',
      'Cache-Control': 'no-cache',
      'Connection': 'keep-alive',
      ..._browserHeaders(),
    };
    if (widget.originalUrl != null) {
      headers['Referer'] = widget.originalUrl!;
      headers['Origin'] = _baseUrl!;
    }

    _httpClient.send(http.Request('GET', Uri.parse(url))..headers.addAll(headers))
        .then((response) {
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
        if (!mounted) return;
        setState(() {
          _errorMessage = 'SSE error: $error';
          _isConnected = false;
          _isConnecting = false;
        });
      }, onDone: () {
        debugPrint('🔌 SSE disconnected');
        if (!mounted) return;
        setState(() {
          _isConnected = false;
          _isConnecting = false;
        });
      });
      _sseSubscription = subscription;
      if (!mounted) return;
      setState(() {
        _isConnected = true;
        _isConnecting = false;
      });
    }).catchError((error) {
      debugPrint('❌ Failed to connect SSE: $error');
      if (!mounted) return;
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
          if (!mounted) return;
          setState(() {
            _errorMessage = 'WebSocket error: $error';
            _isConnected = false;
            _isConnecting = false;
          });
        },
        onDone: () {
          debugPrint('🔌 WebSocket disconnected');
          if (!mounted) return;
          setState(() {
            _isConnected = false;
            _isConnecting = false;
          });
        },
      );
    } catch (e) {
      debugPrint('❌ Failed to connect WebSocket: $e');
      if (!mounted) return;
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
      if (!mounted) return;
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

    // Capture session ID from any event
    final session = json['session'] as String?;
    if (session != null && session.isNotEmpty) {
      _sseSessionId = session;
      debugPrint('📌 Captured session ID: $_sseSessionId');
    }

    final sender = json['sender'] ?? '';
    final isUnstable = json['unstable'] == true;
    final start = json['start']?.toString() ?? '';

    String transcriptText = '';
    Uint8List? audioBytes;

    // ---------- TTS messages (audio + text) ----------
    if (sender.startsWith('tts:')) {
      final text = json['text'] as String?;
      if (text == null || text.trim().isEmpty) {
        debugPrint('⏭️ Skipping TTS with empty text');
        return;
      }
      transcriptText = _cleanTranscript(text);

      final audioUrlPath = json['b64_enc_pcm_s16le'] as String?;
      if (audioUrlPath != null) {
        try {
          String audioUrl = audioUrlPath.startsWith('http')
              ? audioUrlPath
              : '$_baseUrl$audioUrlPath';

          // Add all possible session identifiers as query parameters
          final uri = Uri.parse(audioUrl);
          final params = Map<String, String>.from(uri.queryParameters);
          if (_sseSessionId != null) {
            params['session'] = _sseSessionId!;
            params['sid'] = _sseSessionId!;
            params['channel'] = _sseSessionId!;
            params['token'] = _sseSessionId!;
            params['stream'] = _sseSessionId!;
          }
          audioUrl = uri.replace(queryParameters: params).toString();

          debugPrint('🎵 Fetching audio from: $audioUrl');

          final headers = {
            ..._browserHeaders(),
          };
          if (widget.originalUrl != null) {
            headers['Referer'] = widget.originalUrl!;
            headers['Origin'] = _baseUrl!;
          }

          // Read stored cookies from secure storage
          final String? cookies = await _secureStorage.read(key: 'cookies');
          if (cookies != null && cookies.isNotEmpty) {
            headers['Cookie'] = cookies;
          }

          // Try all possible authentication headers
          if (_sseSessionId != null) {
            headers['X-Session-Id'] = _sseSessionId!;
            headers['X-Stream-Id'] = _sseSessionId!;
            headers['Authorization'] = 'Bearer $_sseSessionId';
            headers['X-Token'] = _sseSessionId!;
          }

          debugPrint('📦 Headers: $headers');

          final response = await _httpClient.get(
            Uri.parse(audioUrl),
            headers: headers,
          ).timeout(const Duration(seconds: 15));

          if (response.statusCode == 200) {
            audioBytes = response.bodyBytes;
            debugPrint('✅ Downloaded audio: ${audioBytes.length} bytes');
          } else {
            debugPrint('❌ Failed to fetch audio: HTTP ${response.statusCode}');
          }
        } catch (e) {
          debugPrint('❌ Error fetching audio: $e');
        }
      } else {
        debugPrint('⚠️ No audio URL in TTS message');
      }

      // Add to language filter
      const language = 'TTS';
      _availableLanguages.add(language);
      if (!_defaultFilterSet) {
        if (mounted) {
          setState(() {
            _selectedLanguage = language;
            _defaultFilterSet = true;
          });
        }
      }

      final key = 'tts_${json['message_id'] ?? DateTime.now().millisecondsSinceEpoch}';

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
          });
        } catch (e) {
          debugPrint('⚠️ Could not save to Firestore: $e');
        }
      }

      if (!mounted) return;
      setState(() {
        _isConnected = true;
        _isConnecting = false;
      });
      _scrollToBottom();
      return;
    }

    // ---------- All other messages (no audio) ----------
    transcriptText = (json['text'] ?? json['seq'] ?? '').toString().trim();
    transcriptText = _cleanTranscript(transcriptText);

    if (transcriptText.isEmpty) {
      debugPrint('⏭️ Skipping message with empty text/seq');
      return;
    }

    final language = _extractLanguageFromSender(sender);

    if (!language.contains('Audio') && !language.contains('Correction')) {
      _availableLanguages.add(language);
    }

    if (!_defaultFilterSet && !language.contains('Audio') && !language.contains('Correction')) {
      if (mounted) {
        setState(() {
          _selectedLanguage = language;
          _defaultFilterSet = true;
        });
      }
    }

    String key;
    if (start.isNotEmpty) {
      key = '$sender|$start';
    } else {
      final textPrefix = transcriptText.length > 20
          ? transcriptText.substring(0, 20)
          : transcriptText;
      key = '$sender|$textPrefix';
    }

    _messagesMap[key] = TranscriptMessage(
      transcript: transcriptText,
      translations: {},
      timestamp: DateTime.now(),
      language: language,
      isUnstable: isUnstable,
      audioData: null,
    );

    if (_transcriptsRef != null) {
      try {
        await _transcriptsRef!.add({
          'transcript': transcriptText,
          'translations': {},
          'timestamp': Timestamp.fromDate(DateTime.now()),
          'language': language,
          'isUnstable': isUnstable,
        });
      } catch (e) {
        debugPrint('⚠️ Could not save to Firestore: $e');
      }
    }

    if (!mounted) return;
    setState(() {
      _isConnected = true;
      _isConnecting = false;
    });
    _scrollToBottom();
  }

  Future<void> _playPause(String key, Uint8List audioData) async {
    if (_playingKey == key) {
      if (_isAudioPlaying) {
        await _audioPlayer.pause();
        if (!mounted) return;
        setState(() => _isAudioPlaying = false);
      } else {
        await _audioPlayer.resume();
        if (!mounted) return;
        setState(() => _isAudioPlaying = true);
      }
    } else {
      await _audioPlayer.stop();
      if (!mounted) return;
      setState(() {
        _playingKey = null;
        _isAudioPlaying = false;
      });

      try {
        await _audioPlayer.setSourceBytes(audioData);
        await _audioPlayer.resume();
        if (!mounted) return;
        setState(() {
          _playingKey = key;
          _isAudioPlaying = true;
          _progressMap[key] = 0.0;
        });
      } catch (e) {
        debugPrint('Error playing audio: $e');
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Audio playback error: $e')),
        );
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
    if (!mounted) return;
    Navigator.pushReplacementNamed(context, '/scan');
  }

  @override
  void dispose() {
    _channel?.sink.close();
    _sseSubscription?.cancel();
    _sseSubscription = null;
    _audioPlayer.dispose();
    _scrollController.dispose();
    _httpClient.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final sortedKeys = _messagesMap.keys.toList()
      ..sort((a, b) => _messagesMap[a]!.timestamp.compareTo(_messagesMap[b]!.timestamp));

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
                          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.center,
                            children: [
                              Expanded(
                                child: Text(
                                  message.transcript,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontSize: 16,
                                    color: message.isUnstable ? Colors.grey : Colors.black,
                                  ),
                                ),
                              ),
                              if (hasAudio) ...[
                                const SizedBox(width: 8),
                                IconButton(
                                  icon: Icon(
                                    _playingKey == key && _isAudioPlaying
                                        ? Icons.pause
                                        : Icons.play_arrow,
                                  ),
                                  onPressed: () => _playPause(key, message.audioData!),
                                  padding: EdgeInsets.zero,
                                  constraints: const BoxConstraints(),
                                ),
                                const SizedBox(width: 4),
                                SizedBox(
                                  width: 60,
                                  child: LinearProgressIndicator(
                                    value: _progressMap[key] ?? 0.0,
                                    backgroundColor: Colors.grey[300],
                                  ),
                                ),
                                const SizedBox(width: 4),
                                Text(
                                  _durationMap[key] != null
                                      ? '${_durationMap[key]!.inSeconds}s'
                                      : '',
                                  style: const TextStyle(fontSize: 12),
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