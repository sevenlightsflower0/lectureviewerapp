class TranscriptMessage {
  final String transcript;
  final Map<String, String> translations;
  final DateTime timestamp;
  final String language;
  final bool isUnstable;

  TranscriptMessage({
    required this.transcript,
    this.translations = const {},
    required this.timestamp,
    this.language = 'unknown',      // default fallback
    this.isUnstable = false,
  });

  factory TranscriptMessage.fromJson(Map<String, dynamic> json) {
    return TranscriptMessage(
      transcript: json['transcript'] ?? '',
      translations: Map<String, String>.from(json['translations'] ?? {}),
      timestamp: DateTime.now(),
    );
  }
}