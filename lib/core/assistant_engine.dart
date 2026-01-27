import 'dart:convert';
import 'dart:typed_data';

import '../vision/openai_vision.dart';
import '../vision/yolo_client.dart';

enum _Verbosity { normal, short, detailed }

class AssistantEngine {
  final OpenAiVisionClient visionClient;
  final YoloClient yoloClient;
  final Future<void> Function(String text) speak;
  final Future<Uint8List?> Function() getLatestFrameJpeg;
  final Future<Uint8List?> Function() capturePhotoJpegFallback;
  final Future<void> Function(double volume)? setTtsVolume;

  String _lastResult = '';
  Uint8List? _lastFrameJpeg;

  AssistantEngine({
    required this.visionClient,
    required this.yoloClient,
    required this.speak,
    required this.getLatestFrameJpeg,
    required this.capturePhotoJpegFallback,
    this.setTtsVolume,
  });

  String get lastResult => _lastResult;

  Future<String?> handleIntent(String intent) async {
    switch (intent) {
      case 'repeat':
        final text = _lastResult.isEmpty ? 'Пока нечего повторять.' : _lastResult;
        await speak(text);
        return _lastResult.isEmpty ? null : _lastResult;

      case 'summarize_short':
        return _summarizeLastResult();

      case 'tts_louder':
        if (setTtsVolume != null) {
          await setTtsVolume!(1.0);
        }
        await speak('Громче.');
        return null;

      case 'tts_quieter':
        if (setTtsVolume != null) {
          await setTtsVolume!(0.5);
        }
        await speak('Тише.');
        return null;

      case 'vision_describe':
        return _describe(verbosity: _Verbosity.normal, useLastFrame: false);

      case 'vision_more':
        return _describe(verbosity: _Verbosity.detailed, useLastFrame: true);

      case 'vision_ahead':
        return _yoloDirection('ahead', _Verbosity.normal);
      case 'vision_left':
        return _yoloDirection('left', _Verbosity.normal);
      case 'vision_right':
        return _yoloDirection('right', _Verbosity.normal);
      case 'vision_behind':
        return _yoloDirection('behind', _Verbosity.normal);

      case 'vision_describe_detailed_last':
        return _describe(verbosity: _Verbosity.detailed, useLastFrame: true);

      default:
        if (intent.startsWith('vision_')) {
          final parsed = _parseVisionIntent(intent);
          if (parsed != null) {
            if (parsed.useYolo) {
              return _yoloDirection(parsed.direction!, parsed.verbosity);
            }
            return _describe(
              verbosity: parsed.verbosity,
              useLastFrame: parsed.useLastFrame,
            );
          }
        }
        await speak('Команда не распознана. Скажи: "Жанарым, что впереди".');
        return null;
    }
  }

  Future<String> describeJpegBytes(Uint8List jpeg, {required bool detailed}) async {
    final verbosity = detailed ? _Verbosity.detailed : _Verbosity.normal;
    return _describeJpegBytes(jpeg, verbosity: verbosity);
  }

  Future<String> _describeJpegBytes(Uint8List jpeg, {required _Verbosity verbosity}) async {
    _lastFrameJpeg = jpeg;

    final base64Image = base64Encode(jpeg);
    final prompt = _buildVisionPrompt(verbosity: verbosity);

    final text = await visionClient.describeBase64Jpeg(
      base64Image: base64Image,
      prompt: prompt,
    );

    _lastResult = text;
    await speak(text);
    return text;
  }

  Future<String?> _describe({
    required _Verbosity verbosity,
    required bool useLastFrame,
  }) async {
    await speak(_introForDescribe(verbosity, useLastFrame));

    Uint8List? jpeg;
    if (useLastFrame) {
      if (_lastFrameJpeg == null) {
        await speak('Нет последнего кадра. Сначала скажи "Жанарым, опиши".');
        return null;
      }
      jpeg = _lastFrameJpeg;
    } else {
      jpeg = await getLatestFrameJpeg();
      jpeg ??= await capturePhotoJpegFallback();
    }

    if (jpeg == null) {
      await speak('Не получилось получить изображение.');
      return null;
    }

    return _describeJpegBytes(jpeg, verbosity: verbosity);
  }

  Future<String?> _yoloDirection(String direction, _Verbosity verbosity) async {
    if (yoloClient.baseUrl.trim().isEmpty) {
      await speak('YOLO сервер не настроен.');
      return null;
    }

    final directionRu = _directionRu(direction);
    await speak('Секунду. Смотрю $directionRu.');

    Uint8List? jpeg = await getLatestFrameJpeg();
    jpeg ??= await capturePhotoJpegFallback();

    if (jpeg == null) {
      await speak('Не получилось получить изображение.');
      return null;
    }

    _lastFrameJpeg = jpeg;

    final detections = await yoloClient.detectJpeg(jpeg);

    if (detections.isEmpty) {
      final text = 'Я не вижу объектов $directionRu.';
      _lastResult = text;
      await speak(text);
      return text;
    }

    detections.sort((a, b) => b.conf.compareTo(a.conf));
    final minConf = 0.35;
    final filtered = detections.where((d) => d.conf >= minConf).toList();

    final summary = _buildYoloSummary(
      directionRu: directionRu,
      detections: filtered,
      verbosity: verbosity,
    );

    _lastResult = summary;
    await speak(summary);
    return summary;
  }

  Future<String?> _summarizeLastResult() async {
    if (_lastResult.trim().isEmpty) {
      await speak('Пока нечего сокращать.');
      return null;
    }
    final summary = _shortenText(_lastResult);
    _lastResult = summary;
    await speak(summary);
    return summary;
  }

  String _shortenText(String text) {
    final t = text.trim();
    if (t.isEmpty) return t;
    final parts = t.split(RegExp(r'(?<=[.!?])\\s+'));
    final selected = parts.take(2).join(' ').trim();
    if (selected.length <= 200) return selected;
    return '${selected.substring(0, 200).trim()}…';
  }

  _ParsedVisionIntent? _parseVisionIntent(String intent) {
    final parts = intent.split('_');
    if (parts.length < 3) return null;
    if (parts[0] != 'vision') return null;

    final target = parts[1];
    final verbosity = _verbosityFromString(parts[2]);

    if (target == 'describe') {
      return _ParsedVisionIntent(
        verbosity: verbosity,
        useLastFrame: false,
        useYolo: false,
      );
    }

    if (_isDirection(target)) {
      return _ParsedVisionIntent(
        verbosity: verbosity,
        useLastFrame: false,
        useYolo: true,
        direction: target,
      );
    }

    return null;
  }

  _Verbosity _verbosityFromString(String value) {
    switch (value) {
      case 'short':
        return _Verbosity.short;
      case 'detailed':
        return _Verbosity.detailed;
      case 'normal':
      default:
        return _Verbosity.normal;
    }
  }

  bool _isDirection(String value) {
    return value == 'ahead' ||
        value == 'left' ||
        value == 'right' ||
        value == 'behind';
  }

  String _directionRu(String direction) {
    switch (direction) {
      case 'ahead':
        return 'впереди';
      case 'left':
        return 'слева';
      case 'right':
        return 'справа';
      case 'behind':
        return 'сзади';
      default:
        return 'впереди';
    }
  }

  String _introForDescribe(_Verbosity verbosity, bool useLastFrame) {
    if (useLastFrame) {
      return 'Подробно опишу последний кадр.';
    }
    switch (verbosity) {
      case _Verbosity.short:
        return 'Секунду. Скажу кратко.';
      case _Verbosity.detailed:
        return 'Секунду. Подробно опишу.';
      case _Verbosity.normal:
        return 'Окей. Опишу.';
    }
  }

  String _buildVisionPrompt({required _Verbosity verbosity, String? directionRu}) {
    final directionLine = directionRu == null
        ? 'Опиши всю сцену.'
        : 'Опиши только то, что $directionRu.';

    const common = '''
Ты — Janarym, ассистент для незрячего пользователя.
Ответ — только описание, без вопросов и без мета-текста.
Язык: русский. Тон: спокойный, поддерживающий, практичный.
''';

    switch (verbosity) {
      case _Verbosity.short:
        return '''
$common
$directionLine
Дай 1-2 коротких предложения.
Только самое важное: ключевые объекты и явные опасности.
''';
      case _Verbosity.detailed:
        return '''
$common
$directionLine
Дай структурированное описание.
Укажи объекты и их позиции, явно выдели опасности.
Если виден текст — перепиши его точно.
''';
      case _Verbosity.normal:
        return '''
$common
$directionLine
Дай 2-5 предложений.
Опиши главные объекты, их расположение и возможные опасности.
''';
    }
  }

  String _buildYoloSummary({
    required String directionRu,
    required List<YoloDetection> detections,
    required _Verbosity verbosity,
  }) {
    if (detections.isEmpty) {
      return 'Я не вижу объектов $directionRu.';
    }

    final maxItems = switch (verbosity) {
      _Verbosity.short => 3,
      _Verbosity.normal => 6,
      _Verbosity.detailed => 10,
    };

    final labelCounts = <String, int>{};
    for (final d in detections.take(maxItems * 2)) {
      labelCounts[d.label] = (labelCounts[d.label] ?? 0) + 1;
      if (labelCounts.length >= maxItems && verbosity != _Verbosity.detailed) {
        break;
      }
    }

    if (verbosity == _Verbosity.detailed) {
      final parts = labelCounts.entries
          .map((e) => e.value > 1 ? '${e.key} (${e.value})' : e.key)
          .take(maxItems)
          .toList();
      return 'С $directionRu я вижу: ${parts.join(', ')}.';
    }

    final labels = labelCounts.keys.take(maxItems).toList();
    return 'С $directionRu я вижу: ${labels.join(', ')}.';
  }
}

class _ParsedVisionIntent {
  final _Verbosity verbosity;
  final bool useLastFrame;
  final bool useYolo;
  final String? direction;

  _ParsedVisionIntent({
    required this.verbosity,
    required this.useLastFrame,
    required this.useYolo,
    this.direction,
  });
}
