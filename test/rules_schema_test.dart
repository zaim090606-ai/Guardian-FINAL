import 'dart:io';

import 'package:easy_help/logic/alert_schema.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final rules = File('firestore.rules.proposed');
  final text = rules.existsSync() ? rules.readAsStringSync() : '';
  final cut = text.indexOf('match /private/');
  final publicPart = cut < 0 ? text : text.substring(0, cut);
  final privatePart = cut < 0 ? '' : text.substring(cut);

  test('rules file is present and has the private subdocument', () {
    expect(text, isNotEmpty);
    expect(cut, greaterThan(0));
  });

  test('every public key is allowed by the rules', () {
    for (final k in AlertSchema.publicKeys) {
      expect(publicPart.contains("'$k'"), isTrue, reason: 'missing $k');
    }
    for (final k in AlertSchema.relayCreateKeys) {
      expect(publicPart.contains("'$k'"), isTrue, reason: 'missing $k');
    }
  });

  test('personal fields are never allowed in the public document', () {
    for (final k in AlertSchema.privateKeys) {
      expect(publicPart.contains("'$k'"), isFalse, reason: '$k is public');
      expect(privatePart.contains("'$k'"), isTrue, reason: '$k not private');
    }
  });

  test('open rules are not proposed, ids need 20 characters, no list', () {
    expect(RegExp(r'^\s*allow (read, write|write|read): if true', multiLine: true)
        .hasMatch(text), isFalse);
    expect(text.contains('alertId.size() >= 20'), isTrue);
    expect(text.contains('allow list: if false'), isTrue);
  });

  test('split keeps personal data out of the public map and adds the owner', () {
    final r = AlertSchema.split({
      'userPhone': '+911234567890',
      'transcript': 'help',
      'audioUrl': 'https://x',
      'latitude': 1.0,
      'status': 'triggered',
      'bogus': 1,
      'userId': 'attacker',
    }, 'uid1');
    expect(r.public.keys.toSet(), {'userId', 'latitude', 'status'});
    expect(r.public['userId'], 'uid1');
    expect(r.private.keys.toSet(), {'userId', 'userPhone', 'transcript', 'audioUrl'});
    expect(r.private['userId'], 'uid1');
  });

  test('split drops null values so the rules (absent-or-typed) accept the write', () {
    final r = AlertSchema.split({
      'latitude': 1.0,
      'anchorAgeS': null,
      'anchorRadiusM': null,
      'locationFixTimeMs': null,
      'audioUrl': null,
      'audioAnalysis': '',
    }, 'uid1');
    expect(r.public.keys.toSet(), {'userId', 'latitude'});
    expect(r.private.keys.toSet(), {'userId', 'audioAnalysis'});
  });
}
