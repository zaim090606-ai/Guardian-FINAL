/// Start/stop state for Nearby advertising, kept apart from the plugin so the
/// races can be tested.
///
///  * Concurrent [ensureStarted] calls share one in-flight start.
///  * [advertising] is true only when a start really succeeded.
///  * After a failed or unknown start the state is "uncertain", and [stop]
///    still asks the plugin to stop, so advertising can never be left on.
class AdvertisingController {
  /// Starts advertising; true when it really started. May throw.
  final Future<bool> Function() start;

  /// Stops advertising and closes endpoints. May throw.
  final Future<void> Function() stopAll;

  AdvertisingController({required this.start, required this.stopAll});

  bool _advertising = false;
  bool _uncertain = false;
  Future<bool>? _starting;

  bool get advertising => _advertising;
  bool get uncertain => _uncertain;

  Future<bool> ensureStarted() {
    if (_advertising) return Future.value(true);
    return _starting ??= _doStart().whenComplete(() => _starting = null);
  }

  Future<bool> _doStart() async {
    _uncertain = true;
    try {
      final ok = await start();
      _advertising = ok;
      _uncertain = false;
      return ok;
    } catch (_) {
      _advertising = false;
      _uncertain = true;
      return false;
    }
  }

  Future<void> stop() async {
    final inflight = _starting;
    if (inflight != null) {
      try {
        await inflight;
      } catch (_) {}
    }
    if (!_advertising && !_uncertain) return;
    _advertising = false;
    try {
      await stopAll();
      _uncertain = false;
    } catch (_) {
      _uncertain = true; // the next stop() tries again
    }
  }
}
