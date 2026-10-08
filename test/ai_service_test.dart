import 'package:easy_help/services/ai_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  // Tests run without --dart-define, so the key is the placeholder.
  test('Gemini is off with the placeholder key and returns null', () async {
    expect(AIService.isConfigured, isFalse);
    expect(
      await AIService.generateAlert(
        gForce: 1,
        lat: 1,
        lng: 1,
        audioTranscript: '',
        level: 'test',
      ),
      isNull,
    );
    expect(
      await AIService.analyzeIncidentContext(transcript: 'x', acousticLabel: 'y'),
      isNull,
    );
  });
}
