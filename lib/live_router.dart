class LiveCommand {
  final String raw;
  final String intent;
  final Map<String, dynamic> slots;
  LiveCommand(this.raw, this.intent, [this.slots = const {}]);
}

class LiveRouter {
  static const _wakeWords = ['жанарым', 'жаным', 'janarym', 'zhanarym'];

  bool hasWakeWord(String text) {
    final t = text.toLowerCase();
    return _wakeWords.any(t.contains);
  }

  LiveCommand? parse(String text) {
    final t = text.toLowerCase().trim();

    if (!hasWakeWord(t)) return null;

    // убираем wakeword из фразы
    var cmd = t;
    for (final w in _wakeWords) {
      cmd = cmd.replaceAll(w, '').trim();
    }

    // intents (минимальный набор; расширяется таблицей ниже)
    if (cmd.contains('что впереди') ||
        cmd.contains('что спереди') ||
        cmd.contains('впереди')) {
      return LiveCommand(text, 'vision_ahead');
    }
    if (cmd.contains('что сзади') || cmd.contains('сзади')) {
      return LiveCommand(text, 'vision_behind');
    }
    if (cmd.contains('что слева') || cmd.contains('слева')) {
      return LiveCommand(text, 'vision_left');
    }
    if (cmd.contains('что справа') || cmd.contains('справа')) {
      return LiveCommand(text, 'vision_right');
    }

    if (cmd.contains('опиши') || cmd.contains('расскажи что')) {
      return LiveCommand(text, 'vision_describe');
    }

    if (cmd.contains('включи лайв') ||
        cmd.contains('live режим') ||
        cmd.contains('режим лайв')) {
      return LiveCommand(text, 'live_on');
    }
    if (cmd.contains('выключи лайв') ||
        cmd.contains('stop') ||
        cmd.contains('стоп')) {
      return LiveCommand(text, 'live_off');
    }

    if (cmd.contains('повтори')) return LiveCommand(text, 'repeat');
    if (cmd.contains('тише')) return LiveCommand(text, 'tts_quieter');
    if (cmd.contains('громче')) return LiveCommand(text, 'tts_louder');

    // неизвестная команда
    return LiveCommand(text, 'unknown', {'cmd': cmd});
  }
}
