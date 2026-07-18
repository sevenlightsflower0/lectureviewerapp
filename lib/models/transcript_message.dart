// models/transcript_message.dart
import 'dart:typed_data';

class TranscriptMessage {
  final String transcript;
  final Map<String, String> translations;
  final DateTime timestamp;
  final String language;
  final bool isUnstable;
  final Uint8List? audioData; // new

  TranscriptMessage({
    required this.transcript,
    required this.translations,
    required this.timestamp,
    required this.language,
    this.isUnstable = false,
    this.audioData,
  });
}