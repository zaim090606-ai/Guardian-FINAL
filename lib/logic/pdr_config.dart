/// Switches for every PDR improvement. All on by default; each can be turned
/// off (Diagnostics screen, tests) to compare against the plain engine.
class PdrConfig {
  /// Reject magnetometer samples whose field strength is not 25-65 microtesla.
  bool compassGating;

  /// Learn "GPS course minus compass heading" while GPS is good and apply it
  /// when GPS is lost.
  bool headingOffset;

  /// Learn the stride length from GPS distance / steps.
  bool strideLearning;

  /// Use YAMNet sound labels to detect vehicles / standing still.
  bool microphoneContext;

  /// Accept position beacons from nearby Guardian phones with good GPS.
  bool anchors;

  PdrConfig({
    this.compassGating = true,
    this.headingOffset = true,
    this.strideLearning = true,
    this.microphoneContext = true,
    this.anchors = true,
  });

  PdrConfig.allOff()
      : compassGating = false,
        headingOffset = false,
        strideLearning = false,
        microphoneContext = false,
        anchors = false;

  void setAll(bool on) {
    compassGating = headingOffset =
        strideLearning = microphoneContext = anchors = on;
  }

  Map<String, bool> toMap() => {
        'compassGating': compassGating,
        'headingOffset': headingOffset,
        'strideLearning': strideLearning,
        'microphoneContext': microphoneContext,
        'anchors': anchors,
      };

  void applyMap(Map<dynamic, dynamic> m) {
    compassGating = m['compassGating'] == true;
    headingOffset = m['headingOffset'] == true;
    strideLearning = m['strideLearning'] == true;
    microphoneContext = m['microphoneContext'] == true;
    anchors = m['anchors'] == true;
  }
}
