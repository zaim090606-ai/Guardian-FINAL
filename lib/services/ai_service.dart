import 'dart:io';
import 'dart:typed_data';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:google_generative_ai/google_generative_ai.dart';
 
import 'local_whisper_service.dart';
import 'yamnet_service.dart';
 
class GeminiThreatAnalysis {
  final String threatLevel;
  final String threatSummary;
 
  GeminiThreatAnalysis({
    required this.threatLevel,
    required this.threatSummary,
  });
}
 
class AIService {
  static const String _apiKey = String.fromEnvironment('GEMINI_API_KEY', defaultValue: 'Place your key here');

  /// False when no real key was supplied; every Gemini call is then skipped.
  static bool get isConfigured =>
      _apiKey.isNotEmpty && _apiKey != 'Place your key here';
 
  /// Synthesizes speech transcript and acoustic label into structured incident context
  static Future<GeminiThreatAnalysis?> analyzeIncidentContext({
    required String transcript,
    required String acousticLabel,
  }) async {
    try {
      if (_apiKey.isEmpty || _apiKey == 'Place your key here') return null;
 
      final model = GenerativeModel(model: 'gemini-1.5-flash', apiKey: _apiKey);
      final prompt = '''
You are an Emergency Response Intelligence Coordinator for the Guardian safety app.
Analyze the following telemetry captured at the edge:
- Speech Transcript: "${transcript.isEmpty ? 'None recorded' : transcript}"
- Acoustic Shield Tag: "${acousticLabel.isEmpty ? 'None detected' : acousticLabel}"
 
Respond in concise text with format:
THREAT_LEVEL: [CRITICAL/HIGH/MEDIUM/LOW]
SUMMARY: [1-sentence briefing for first responders]
''';
 
      final response = await model.generateContent([Content.text(prompt)]);
      final text = response.text ?? "";
 
      String level = "HIGH";
      String summary = "Voice/Acoustic distress event logged.";
 
      for (var line in text.split('\n')) {
        if (line.startsWith("THREAT_LEVEL:")) {
          level = line.replaceAll("THREAT_LEVEL:", "").trim();
        } else if (line.startsWith("SUMMARY:")) {
          summary = line.replaceAll("SUMMARY:", "").trim();
        }
      }
 
      return GeminiThreatAnalysis(
        threatLevel: level,
        threatSummary: summary,
      );
    } catch (e) {
      debugPrint("⚠️ Gemini Online Enrichment Error: $e");
      return null;
    }
  }
 
  /// Short Gemini-written summary for contacts. Returns null when Gemini is
  /// not configured, unreachable or returns nothing (the SOS never needs it).
  static Future<String?> generateAlert({
    required double gForce,
    required double lat,
    required double lng,
    required String audioTranscript,
    required String level,
  }) async {
    if (!isConfigured) return null;
    try {
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
      final aiText = response.text?.trim();
      if (aiText != null && aiText.isNotEmpty) return aiText;
    } catch (e) {
      debugPrint('Gemini alert summary failed: $e');
    }
    return null;
  }

  /// Analyzes the audio recording natively via Gemini (Online) or local AI (Offline)
  static Future<String> analyzeAudioEvidence(String audioFilePath) async {
    final file = File(audioFilePath);
    if (!await file.exists()) return "Audio file not found for analysis.";
 
    var connectivity = await Connectivity().checkConnectivity();
    bool isOnline = !connectivity.contains(ConnectivityResult.none);
 
    if (isOnline) {
      try {
        debugPrint("🌐 Online: Running Gemini audio analysis...");
        return await _analyzeWithGemini(file);
      } catch (e) {
        debugPrint("⚠️ Gemini API failed ($e). Falling back to offline analysis.");
        return await _analyzeLocally(audioFilePath);
      }
    } else {
      debugPrint("📡 Offline: Directing audio to local Whisper + YAMNet pipeline.");
      return await _analyzeLocally(audioFilePath);
    }
  }
 
  static Future<String> _analyzeWithGemini(File audioFile) async {
 
    final audioBytes = await audioFile.readAsBytes();
    final model = GenerativeModel(model: 'gemini-1.5-flash', apiKey: _apiKey);
 
    final prompt = TextPart('''
      You are an emergency forensic AI. Listen to this 30-second background audio recorded during an SOS event.
      Provide a brief, factual incident report (max 3 sentences). 
      Identify any voices, background noises (e.g., traffic, struggles, alarms), and assess the apparent threat level.
    ''');
 
    final audioPart = DataPart('audio/wav', audioBytes);
 
    final response = await model.generateContent([
      Content.multi([prompt, audioPart])
    ]);
 
    String? aiAnalysis = response.text?.trim();
    debugPrint("🤖 Gemini 30s Audio Analysis: $aiAnalysis");
 
    return aiAnalysis ?? "No clear context detected from audio.";
  }
 
  /// Runs the full offline pipeline: Whisper transcription + YAMNet acoustic
  /// classification, then (if online) sends both to Gemini for a structured
  /// threat assessment. Falls back to a local-only report if offline or if
  /// Gemini enrichment fails.
  static Future<String> _analyzeLocally(String audioPath) async {
    debugPrint("⚙️ Executing local Whisper + YAMNet pipeline...");
 
    // 1. Transcribe speech offline via Whisper
    String transcript = await LocalWhisperService.transcribe(audioPath);
 
    // 2. Classify ambient sound offline via YAMNet
    String acousticLabel = "None detected";
    try {
      final yamnet = YamnetService();
      await yamnet.initialize();
 
      final bytes = await File(audioPath).readAsBytes();
      final samples = _decodeWavPcm16(bytes);
 
      // YAMNet expects ~0.975s (15,600 samples at 16kHz) windows.
      // Slide across the whole recording and keep the strongest detection.
      const int windowSize = 15600;
      double bestConfidence = 0.0;
      String bestLabel = "None detected";
      bool anyDistress = false;
 
      for (int i = 0; i + windowSize <= samples.length; i += windowSize) {
        final chunk = samples.sublist(i, i + windowSize);
        final result = await yamnet.classifyAudioFrame(Float32List.fromList(chunk));
        if (result != null) {
          if (result.isDistress) anyDistress = true;
          if (result.confidence > bestConfidence) {
            bestConfidence = result.confidence;
            bestLabel = result.label;
          }
        }
      }
 
      acousticLabel = anyDistress ? "$bestLabel (distress)" : bestLabel;
      yamnet.dispose();
    } catch (e) {
      debugPrint("⚠️ YAMNet classification failed: $e");
    }
 
    // 3. If online, enrich both results into a structured Gemini assessment
    var connectivity = await Connectivity().checkConnectivity();
    bool isOnline = !connectivity.contains(ConnectivityResult.none);
 
    if (isOnline) {
      final analysis = await analyzeIncidentContext(
        transcript: transcript,
        acousticLabel: acousticLabel,
      );
      if (analysis != null) {
        return "[HYBRID ANALYSIS]\n"
            "Transcript: \"${transcript.isNotEmpty ? transcript : 'No speech detected'}\"\n"
            "Acoustic Event: $acousticLabel\n"
            "Threat Level: ${analysis.threatLevel}\n"
            "Summary: ${analysis.threatSummary}";
      }
    }
 
    // 4. Offline-only or Gemini-failed fallback report
    return "[OFFLINE ANALYSIS]\n"
        "Transcript: \"${transcript.isNotEmpty ? transcript : 'No speech detected'}\"\n"
        "Acoustic Event: $acousticLabel";
  }
 
  /// Decodes a 16-bit PCM mono WAV file (as produced by the `record` package
  /// with AudioEncoder.wav) into normalized float32 samples in range [-1.0, 1.0].
  static Float32List _decodeWavPcm16(Uint8List bytes) {
    const int headerSize = 44; // standard WAV header length
    final dataBytes = bytes.length > headerSize
        ? bytes.sublist(headerSize)
        : Uint8List(0);
    final byteData = ByteData.sublistView(dataBytes);
    final sampleCount = dataBytes.length ~/ 2;
    final samples = Float32List(sampleCount);
    for (int i = 0; i < sampleCount; i++) {
      final int16 = byteData.getInt16(i * 2, Endian.little);
      samples[i] = int16 / 32768.0;
    }
    return samples;
  }
}
