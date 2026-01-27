class LiveCommand {
  final String raw;
  final String intent;
  final Map<String, dynamic> slots;
  LiveCommand(this.raw, this.intent, [this.slots = const {}]);
}

enum _Verbosity { normal, short, detailed }

class LiveRouter {
  static const _wakeWordsRaw = [
    'жанарым',
    'жанарам',
    'жанрам',
    'джанарым',
    'шмарым',
    'жаным',
    'janarym',
    'zhanarym',
  ];

  static const _shortWords = ['короче', 'кратко', 'коротко'];
  static const _detailedWords = ['подробнее', 'подробней', 'детальнее'];

  static const _liveOnWords = [
    'включи лайв',
    'live режим',
    'режим лайв',
  ];
  static const _liveOffWords = ['выключи лайв', 'stop', 'стоп'];
  static const _repeatWords = ['повтори'];
  static const _louderWords = ['громче'];
  static const _quieterWords = ['тише'];

  static const _stopWords = [
    'пожалуйста',
    'плиз',
    'ну',
    'давай',
    'скажи',
    'опиши',
    'расскажи',
    'что',
  ];

  bool hasWakeWord(String text) {
    final t = text.toLowerCase();
    if (_wakeWordsRaw.any(t.contains)) return true;

    final normalized = _normalizeWake(t);
    return RegExp(r'ж[ао]?н[ао]?р[аыи]м').hasMatch(normalized);
  }

  LiveCommand? parse(String text) {
    final t = text.toLowerCase().trim();
    if (!hasWakeWord(t)) return null;

    final cmd = _stripWakeWords(t);

    if (_containsAny(cmd, _liveOnWords)) {
      return LiveCommand(text, 'live_on');
    }
    if (_containsAny(cmd, _liveOffWords)) {
      return LiveCommand(text, 'live_off');
    }
    if (_containsAny(cmd, _repeatWords)) {
      return LiveCommand(text, 'repeat');
    }
    if (_containsAny(cmd, _quieterWords)) {
      return LiveCommand(text, 'tts_quieter');
    }
    if (_containsAny(cmd, _louderWords)) {
      return LiveCommand(text, 'tts_louder');
    }

    final verbosity = _detectVerbosity(cmd);
    final direction = _detectDirection(cmd);

    final onlyVerbosity =
        direction == null && verbosity != _Verbosity.normal && _isOnlyVerbosity(cmd, verbosity);

    if (onlyVerbosity && verbosity == _Verbosity.short) {
      return LiveCommand(text, 'summarize_short');
    }
    if (onlyVerbosity && verbosity == _Verbosity.detailed) {
      return LiveCommand(text, 'vision_describe_detailed_last');
    }

    final target = direction ?? 'describe';
    final verb = _verbosityToString(verbosity);
    final intent = 'vision_${target}_$verb';
    return LiveCommand(text, intent, {
      'verbosity': verb,
      if (direction != null) 'direction': direction,
    });
  }

  bool _containsAny(String text, List<String> words) {
    return words.any(text.contains);
  }

  String _stripWakeWords(String text) {
    var cmd = text;
    for (final w in _wakeWordsRaw) {
      cmd = cmd.replaceAll(w, ' ');
    }
    cmd = cmd.replaceAll(RegExp(r'\s+'), ' ').trim();
    return cmd;
  }

  _Verbosity _detectVerbosity(String cmd) {
    if (_containsAny(cmd, _detailedWords)) return _Verbosity.detailed;
    if (_containsAny(cmd, _shortWords)) return _Verbosity.short;
    return _Verbosity.normal;
  }

  String? _detectDirection(String cmd) {
    if (cmd.contains('впереди') || cmd.contains('спереди')) return 'ahead';
    if (cmd.contains('сзади') || cmd.contains('позади')) return 'behind';
    if (cmd.contains('слева')) return 'left';
    if (cmd.contains('справа')) return 'right';
    return null;
  }

  bool _isOnlyVerbosity(String cmd, _Verbosity verbosity) {
    final words = cmd
        .split(RegExp(r'\\s+'))
        .map((w) => w.trim())
        .where((w) => w.isNotEmpty)
        .toList();

    final verbWords = verbosity == _Verbosity.short ? _shortWords : _detailedWords;
    final remaining = words
        .where((w) => !_stopWords.contains(w) && !verbWords.contains(w))
        .toList();
    return remaining.isEmpty;
  }

  String _normalizeWake(String text) {
    var t = text.toLowerCase();
    t = t.replaceAll('дж', 'ж');
    t = t.replaceAll('ш', 'ж');
    t = t.replaceAll('ё', 'е');
    t = t.replaceAll('й', 'и');
    t = t.replaceAll(RegExp(r'[^a-zа-я]+'), '');
    return _collapseRepeats(t);
  }

  String _collapseRepeats(String text) {
    if (text.isEmpty) return text;
    final buffer = StringBuffer();
    var prev = text[0];
    buffer.write(prev);
    for (var i = 1; i < text.length; i++) {
      final ch = text[i];
      if (ch != prev) {
        buffer.write(ch);
        prev = ch;
      }
    }
    return buffer.toString();
  }

  String _verbosityToString(_Verbosity v) {
    switch (v) {
      case _Verbosity.short:
        return 'short';
      case _Verbosity.detailed:
        return 'detailed';
      case _Verbosity.normal:
        return 'normal';
    }
  }
}
