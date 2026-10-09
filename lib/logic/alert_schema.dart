/// Which alert fields are public (readable by anyone holding the tracking
/// link) and which are private (emergency_logs/{id}/private/details, owner
/// only). Kept in step with firestore.rules.proposed by a test.
class AlertSchema {
  /// Fields of emergency_logs/{id} that the owner may write.
  static const Set<String> publicKeys = {
    'userId',
    'eventType',
    'riskLevel',
    'force',
    'alertMessage',
    'latitude',
    'longitude',
    'locationSource',
    'locationUncertaintyM',
    'isDeadReckoning',
    'locationFixTimeMs',
    'locationAgeS',
    'locationContext',
    'anchorUsed',
    'anchorAgeS',
    'anchorRadiusM',
    'locationSimulated',
    'status',
    'audioStatus',
    'timestamp',
    'lastLiveUpdate',
    'sosAttempts',
  };

  /// Extra fields on a document created by a relaying phone.
  static const Set<String> relayCreateKeys = {
    'relayed',
    'relayedByMesh',
    'relayedAt',
    'relayHop',
    'originTimestamp',
    'simulated',
  };

  /// Fields any signed-in relayer may add to an existing alert.
  static const Set<String> relayUpdateKeys = {
    'relayedByMesh',
    'relayedAt',
    'relayHop',
  };

  /// Personal data kept out of the public document.
  static const Set<String> privateKeys = {
    'userPhone',
    'transcript',
    'audioUrl',
    'audioAnalysis',
    'audioUploadedAt',
    'aiSummary',
  };

  /// Splits [data] into the public document and the private one, adding
  /// [uid] as the owner of both. Unknown keys and null values are dropped: the
  /// rules accept an absent optional field but reject one that is present
  /// and null.
  static ({Map<String, dynamic> public, Map<String, dynamic> private}) split(
      Map<String, dynamic> data, String uid) {
    final pub = <String, dynamic>{'userId': uid};
    final priv = <String, dynamic>{'userId': uid};
    data.forEach((k, v) {
      if (k == 'userId' || v == null) return;
      if (privateKeys.contains(k)) {
        priv[k] = v;
      } else if (publicKeys.contains(k)) {
        pub[k] = v;
      }
    });
    return (public: pub, private: priv);
  }
}
