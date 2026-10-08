import 'dart:async';

/// A one-shot countdown that can be cancelled, used to give the user a chance
/// to stop an automatically detected SOS (false-alarm protection).
class CancelableCountdown {
  Completer<bool>? _completer;
  Timer? _timer;

  bool get isRunning => _completer != null && !_completer!.isCompleted;

  /// Completes with true when the time ran out (go ahead and send) and with
  /// false when [cancel] was called first. Starting a new countdown while one
  /// runs cancels the old one.
  Future<bool> start(Duration duration) {
    cancel();
    final c = Completer<bool>();
    _completer = c;
    _timer = Timer(duration, () {
      if (!c.isCompleted) c.complete(true);
    });
    return c.future;
  }

  void cancel() {
    _timer?.cancel();
    final c = _completer;
    if (c != null && !c.isCompleted) c.complete(false);
  }
}

/// A short, bounded list of timestamped messages for the diagnostics screen.
class EventLog {
  final int capacity;
  final List<({int tsMs, String text})> _items = [];

  EventLog({this.capacity = 10});

  void add(String text, int tsMs) {
    _items.add((tsMs: tsMs, text: text));
    if (_items.length > capacity) _items.removeAt(0);
  }

  /// Newest first.
  List<({int tsMs, String text})> get newestFirst => _items.reversed.toList();

  List<Map<String, dynamic>> toJson() =>
      [for (final e in newestFirst) {'t': e.tsMs, 'm': e.text}];
}
