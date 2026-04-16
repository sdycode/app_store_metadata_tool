class CancelledException implements Exception {
  @override
  String toString() => 'Operation cancelled by user';
}

/// Plain (no ChangeNotifier) replacement of the Flutter app's RunControl.
/// The web UI reads state via GET /status.
class RunState {
  bool _paused = false;
  bool _cancelled = false;
  bool _active = false;
  String _currentAction = '';

  bool get isPaused => _paused;
  bool get isCancelled => _cancelled;
  bool get isActive => _active;
  String get currentAction => _currentAction;

  Map<String, dynamic> toJson() => {
        'active': _active,
        'paused': _paused,
        'cancelled': _cancelled,
        'action': _currentAction,
      };

  void startRun(String action) {
    _paused = false;
    _cancelled = false;
    _active = true;
    _currentAction = action;
  }

  void endRun() {
    _paused = false;
    _active = false;
    _currentAction = '';
  }

  void pause() {
    if (!_active || _cancelled) return;
    _paused = true;
  }

  void resume() {
    _paused = false;
  }

  void cancel() {
    _cancelled = true;
    _paused = false;
  }

  Future<void> checkpoint() async {
    if (_cancelled) throw CancelledException();
    while (_paused && !_cancelled) {
      await Future.delayed(const Duration(milliseconds: 150));
    }
    if (_cancelled) throw CancelledException();
  }
}
