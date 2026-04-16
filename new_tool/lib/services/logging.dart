enum LogLevel { debug, info, warn, error, success }

class LogEntry {
  final int index;
  final DateTime time;
  final LogLevel level;
  final String message;
  final String? scope;

  LogEntry(this.index, this.time, this.level, this.message, this.scope);

  Map<String, dynamic> toJson() => {
        'index': index,
        'time': time.toIso8601String(),
        'level': level.name,
        'message': message,
        'scope': scope,
      };

  String format() {
    final t = time.toIso8601String().split('T').last.split('.').first;
    final tag = scope == null ? '' : '[$scope] ';
    return '$t ${level.name.toUpperCase().padRight(7)} $tag$message';
  }
}

class LoggingService {
  LoggingService._();
  static final LoggingService instance = LoggingService._();

  final List<LogEntry> _entries = [];
  int _nextIndex = 0;

  List<LogEntry> get entries => List.unmodifiable(_entries);

  /// Returns entries with index >= since.
  List<LogEntry> since(int since) =>
      _entries.where((e) => e.index >= since).toList(growable: false);

  void clear() {
    _entries.clear();
    _nextIndex = 0;
  }

  void _log(LogLevel level, String message, {String? scope}) {
    final e = LogEntry(_nextIndex++, DateTime.now(), level, message, scope);
    _entries.add(e);
    print(e.format());
  }

  void debug(String m, {String? scope}) => _log(LogLevel.debug, m, scope: scope);
  void info(String m, {String? scope}) => _log(LogLevel.info, m, scope: scope);
  void warn(String m, {String? scope}) => _log(LogLevel.warn, m, scope: scope);
  void error(String m, {String? scope}) => _log(LogLevel.error, m, scope: scope);
  void success(String m, {String? scope}) =>
      _log(LogLevel.success, m, scope: scope);
}
