class TranscriptMessage {
  final String transcript;
  final Map<String, String> translations;
  final DateTime timestamp;

  TranscriptMessage({
    required this.transcript,
    required this.translations,
    required this.timestamp,
  });

  factory TranscriptMessage.fromJson(Map<String, dynamic> json) {
    return TranscriptMessage(
      transcript: json['transcript'] ?? '',
      translations: Map<String, String>.from(json['translations'] ?? {}),
      timestamp: DateTime.now(),
    );
  }
}