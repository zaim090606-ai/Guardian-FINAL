import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:google_generative_ai/google_generative_ai.dart';

class AIService {
  // Your API Key from Google AI Studio
  static const String _apiKey = "AQ.Ab8RN6I5_NhrfCwWCM1ZtUqwQAf3F68mZOkTwFhFw-c9IP7mnw";

  static Future<String> generateAlert({
    required double gForce,
    required double lat,
    required double lng,
    required String audioTranscript,
    required String level,
  }) async {
    try {
      if (_apiKey.isEmpty) {
        return _buildFallbackMessage(gForce, lat, lng, audioTranscript, level);
      }

      final model = GenerativeModel(model: 'gemini-1.5-flash', apiKey: _apiKey);
      final prompt = '''
You are an emergency response AI for a safety app called Guardian.
Create a concise emergency message for contacts/first responders based on this real-time data:
- Risk Level: $level
- Impact Force: ${gForce.toStringAsFixed(1)} m/s²
- Live Location: https://maps.google.com/?q=$lat,$lng
- Spoken Audio Transcript: "${audioTranscript.isEmpty ? 'None recorded' : audioTranscript}"

Format requirements:
- Maximum 2 sentences.
- Include the location link.
- Keep it clear, urgent, and factual.
''';

      final response = await model.generateContent([Content.text(prompt)]);
      String? aiText = response.text?.trim();

      if (aiText != null && aiText.isNotEmpty) {
        debugPrint("🤖 Gemini Context Generated: $aiText");
        return aiText;
      }
      return _buildFallbackMessage(gForce, lat, lng, audioTranscript, level);
    } catch (e) {
      debugPrint("❌ Gemini AI Error: $e. Falling back to default format.");
      return _buildFallbackMessage(gForce, lat, lng, audioTranscript, level);
    }
  }

  /// Analyzes the full 30-second audio recording natively
  static Future<String> analyzeAudioEvidence(String audioFilePath) async {
    try {
      if (_apiKey.isEmpty) return "API Key missing.";

      final file = File(audioFilePath);
      if (!await file.exists()) return "Audio file not found for analysis.";

      final audioBytes = await file.readAsBytes();
      final model = GenerativeModel(model: 'gemini-1.5-flash', apiKey: _apiKey);
      
      final prompt = TextPart('''
        You are an emergency forensic AI. Listen to this 30-second background audio recorded during an SOS event.
        Provide a brief, factual incident report (max 3 sentences). 
        Identify any voices, background noises (e.g., traffic, struggles, alarms), and assess the apparent threat level.
      ''');
      
      // Note: Ensure your AudioRecorderService saves as .m4a, .mp3, or .mp4
      final audioPart = DataPart('audio/mp4', audioBytes); 

      final response = await model.generateContent([
        Content.multi([prompt, audioPart])
      ]);

      String? aiAnalysis = response.text?.trim();
      debugPrint("🤖 Gemini 30s Audio Analysis: $aiAnalysis");
      
      return aiAnalysis ?? "No clear context detected from audio.";
    } catch (e) {
      debugPrint("❌ Gemini Audio Analysis Error: $e");
      return "Audio analysis failed due to an error.";
    }
  }

  static String _buildFallbackMessage(
    double gForce,
    double lat,
    double lng,
    String transcript,
    String level,
  ) {
    String mapsLink = (lat != 0.0 && lng != 0.0)
        ? "https://maps.google.com/?q=$lat,$lng"
        : "Location Unavailable";

    String contextStr = transcript.isNotEmpty ? " Spoken Context: '$transcript'" : "";
    return "SOS! Guardian Alert ($level, Force: ${gForce.toStringAsFixed(1)}).$contextStr Location: $mapsLink";
  }
}