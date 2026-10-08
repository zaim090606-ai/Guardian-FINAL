import 'dart:typed_data';

import 'package:easy_help/logic/trigger_logic.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('matchKeyword', () {
    const kws = ['help', 'sos', 'save me', 'call police'];

    test('matches whole words ignoring case and punctuation', () {
      expect(matchKeyword('HELP!', kws), 'help');
      expect(matchKeyword('please, save me now', kws), 'save me');
      expect(matchKeyword('Call police.', kws), 'call police');
    });

    test('does not match inside other words', () {
      expect(matchKeyword('this is helpful', kws), isNull);
      expect(matchKeyword('sosa', kws), isNull);
    });

    test('keeps non-latin letters so Devanagari keywords match', () {
      expect(matchKeyword('कृपया बचाओ!', const ['बचाओ']), 'बचाओ');
    });

    test('empty transcript or keyword list', () {
      expect(matchKeyword('', kws), isNull);
      expect(matchKeyword('help', const []), isNull);
      expect(matchKeyword('help', const ['']), isNull);
    });
  });

  group('silence gate', () {
    test('zeros are silent, a loud tone is not', () {
      expect(isSilent(Float32List(1000)), isTrue);
      final loud = Float32List.fromList(List.filled(1000, 0.3));
      expect(isSilent(loud), isFalse);
      expect(rms(loud), closeTo(0.3, 1e-6));
      expect(rms(Float32List(0)), 0);
    });
  });

  group('DistressClassifier', () {
    final labels = ['Speech', 'Screaming', 'Siren', 'Music', 'Dog'];
    final c = DistressClassifier(labels);

    test('flags a strong distress class', () {
      final r = c.classify([0.1, 0.8, 0.0, 0.0, 0.0]);
      expect(r.isDistress, isTrue);
      expect(r.distressLabel, 'Screaming');
    });

    test('scream under louder speech still counts', () {
      final r = c.classify([0.9, 0.55, 0.0, 0.0, 0.0]);
      expect(r.topLabel, 'Speech');
      expect(r.isDistress, isTrue);
    });

    test('weak or non-distress scores do not trigger', () {
      expect(c.classify([0.1, 0.3, 0.2, 0.0, 0.0]).isDistress, isFalse);
      expect(c.classify([0.0, 0.0, 0.0, 0.9, 0.0]).isDistress, isFalse);
    });

    test('siren triggers', () {
      expect(c.classify([0.0, 0.0, 0.7, 0.0, 0.0]).distressLabel, 'Siren');
    });

    test('labels without distress classes never trigger', () {
      final none = DistressClassifier(['A', 'B']);
      expect(none.hasDistressClasses, isFalse);
      expect(none.classify([1.0, 1.0]).isDistress, isFalse);
    });

    test('short score vector does not crash', () {
      expect(c.classify([0.9]).isDistress, isFalse);
      expect(c.classify([]).isDistress, isFalse);
    });
  });

  group('DistressDebouncer', () {
    test('needs 2 of last 3 windows', () {
      final d = DistressDebouncer();
      expect(d.add(true), isFalse);
      expect(d.add(false), isFalse);
      expect(d.add(true), isTrue);
    });

    test('old windows fall out', () {
      final d = DistressDebouncer();
      d.add(true);
      d.add(false);
      d.add(false);
      expect(d.add(false), isFalse);
      expect(d.add(true), isFalse);
    });

    test('reset clears history', () {
      final d = DistressDebouncer();
      d.add(true);
      d.reset();
      expect(d.add(true), isFalse);
    });
  });

  group('decideTrigger', () {
    test('acoustic wins and names the class', () {
      final r = decideTrigger(
        acousticConfirmed: true,
        acousticLabel: 'Screaming',
        acousticScore: 0.82,
        transcript: '',
        keywords: const ['help'],
      );
      expect(r, contains('Screaming'));
      expect(r, contains('82%'));
    });

    test('keyword triggers when audio is calm', () {
      final r = decideTrigger(
          acousticConfirmed: false,
          transcript: 'somebody help me',
          keywords: const ['help']);
      expect(r, contains('help'));
    });

    test('nothing to report returns null', () {
      expect(
          decideTrigger(
              acousticConfirmed: false,
              transcript: 'nice weather',
              keywords: const ['help']),
          isNull);
    });
  });

  group('shouldRunWhisper gate', () {
    bool run({
      bool whisper = true,
      bool yamnet = true,
      double speech = 0,
      bool user = false,
      bool confirmed = false,
    }) =>
        shouldRunWhisper(
          whisperAvailable: whisper,
          yamnetAvailable: yamnet,
          speechScore: speech,
          userRequested: user,
          acousticConfirmed: confirmed,
        );

    test('stays off while YAMNet hears no speech', () {
      expect(run(speech: 0.05), isFalse);
    });
    test('runs once YAMNet flags speech/scream/siren', () {
      expect(run(speech: 0.6), isTrue);
    });
    test('runs when the user taps the button', () {
      expect(run(user: true), isTrue);
    });
    test('never runs without the engine or after a confirmed acoustic hit', () {
      expect(run(whisper: false, user: true, speech: 1), isFalse);
      expect(run(confirmed: true, speech: 1), isFalse);
    });
    test('without YAMNet there is no gate', () {
      expect(run(yamnet: false), isTrue);
    });
  });

  test('classifier reports speechScore from speech-like classes', () {
    final c = DistressClassifier(['Speech', 'Siren', 'Dog']);
    expect(c.classify([0.7, 0.0, 0.1]).speechScore, 0.7);
    expect(c.classify([0.0, 0.0, 0.9]).speechScore, 0.0);
  });
}
