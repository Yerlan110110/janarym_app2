import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:image_picker/image_picker.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:speech_to_text/speech_to_text.dart' as stt;
import 'package:permission_handler/permission_handler.dart';

import 'live_router.dart';
import 'yolo_client.dart';

/// ======================
/// Janarym MVP (Flutter)
/// Live STT ("Жанарым ... команда") + OpenAI Vision + (опционально) YOLO server
/// ======================

void main() {
  runApp(const JanarymApp());
}

class JanarymApp extends StatelessWidget {
  const JanarymApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Janarym',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(useMaterial3: true, brightness: Brightness.dark),
      home: const JanarymHome(),
    );
  }
}

class JanarymHome extends StatefulWidget {
  const JanarymHome({super.key});

  @override
  State<JanarymHome> createState() => _JanarymHomeState();
}

class _JanarymHomeState extends State<JanarymHome> {
  // ====== CONFIG ======
  // ⚠️ Не храни ключ в репо. Этот placeholder — ок для локального MVP.
  static const String OPENAI_API_KEY = 'PASTE_YOUR_OPENAI_API_KEY_HERE';
  static const String OPENAI_MODEL = 'gpt-4.1-mini';

  /// YOLO сервер (FastAPI + Ultralytics). Если сервера нет — просто оставь пустым.
  static const String YOLO_SERVER_URL = 'http://192.168.1.10:8000';
  // ====================

  final _picker = ImagePicker();
  final _tts = FlutterTts();
  final _stt = stt.SpeechToText();

  final LiveRouter _router = LiveRouter();
  late final YoloClient _yolo = YoloClient(YOLO_SERVER_URL);

  bool _listening = false; // микрофон слушает
  bool _busy = false; // выполняется действие (не слушаем/не принимаем)
  bool _liveMode = true; // "как алиса": слушаем и реагируем на "Жанарым ..."

  String _status = 'Готов. Нажми "Голос" и говори: "Жанарым, что впереди"';
  String _lastText = '';
  String _result = '';

  XFile? _image; // последнее фото (галерея/камера)

  @override
  void initState() {
    super.initState();
    _initTts();
    _initPermissions();
  }

  Future<void> _initPermissions() async {
    await [
      Permission.microphone,
      Permission.camera,
      Permission.photos, // iOS
      Permission.storage, // Android legacy
    ].request();
  }

  Future<void> _initTts() async {
    await _tts.setLanguage('ru-RU');
    await _tts.setSpeechRate(0.45);
    await _tts.setPitch(1.0);
  }

  Future<void> _speak(String text) async {
    final t = text.trim();
    if (t.isEmpty) return;
    await _tts.stop();
    await _tts.speak(t);
  }

  Future<void> _toggleListening() async {
    if (_busy) return;

    if (_listening) {
      setState(() {
        _listening = false;
        _status = 'Остановлено.';
      });
      await _stt.stop();
      return;
    }

    final available = await _stt.initialize(
      onError: (e) {
        setState(() {
          _listening = false;
          _status = 'STT error: ${e.errorMsg} (perm=${e.permanent})';
        });
      },
      onStatus: (s) {
        setState(() => _status = 'STT status: $s');
      },
    );

    final hasMic = await Permission.microphone.isGranted;
    final locales = await _stt.locales();
    final sysLocale = await _stt.systemLocale();

    setState(() {
      _status =
          'STT available=$available | mic=$hasMic | system=${sysLocale?.localeId} | locales=${locales.length}';
    });

    setState(() {
      _listening = true;
      _status = _liveMode
          ? 'Live режим: слушаю. Скажи "Жанарым ..."'
          : 'Слушаю (не live).';
    });

    // В live режиме не останавливаемся после результата.
    await _stt.listen(
      localeId: 'ru_RU',
      listenMode: stt.ListenMode.confirmation,
      onResult: (res) async {
        if (!_listening) return;
        if (_busy) return;

        final text = res.recognizedWords.trim();
        if (text.isEmpty) return;

        setState(() => _lastText = text);

        // Парсим команды только если есть wake word "Жанарым..."
        final cmd = _router.parse(text);
        if (cmd == null) return;

        await _handleCommand(cmd);
      },
    );
  }

  Future<void> _handleCommand(LiveCommand cmd) async {
    // Чтобы не получать 2 раза один и тот же результат из STT,
    // на время выполнения команды ставим busy.
    setState(() {
      _busy = true;
      _status = 'Команда: ${cmd.intent}';
    });

    try {
      switch (cmd.intent) {
        case 'live_on':
          setState(() {
            _liveMode = true;
            _status = 'Live режим включён. Скажи "Жанарым ..."';
          });
          await _speak('Лайв режим включён.');
          break;

        case 'live_off':
          setState(() {
            _liveMode = false;
            _status = 'Live режим выключен.';
          });
          await _speak('Лайв режим выключен.');
          break;

        case 'repeat':
          await _speak(_result.isEmpty ? 'Пока нечего повторять.' : _result);
          break;

        case 'tts_louder':
          await _tts.setVolume(1.0);
          await _speak('Громче.');
          break;

        case 'tts_quieter':
          await _tts.setVolume(0.5);
          await _speak('Тише.');
          break;

        // ===== Vision intents =====
        case 'vision_describe':
          await _voiceDescribeWithOpenAI();
          break;

        case 'vision_ahead':
          await _voiceYoloDirection('впереди');
          break;
        case 'vision_left':
          await _voiceYoloDirection('слева');
          break;
        case 'vision_right':
          await _voiceYoloDirection('справа');
          break;
        case 'vision_behind':
          await _voiceYoloDirection('сзади');
          break;

        case 'unknown':
        default:
          await _speak('Команда не распознана. Скажи: "Жанарым, что впереди".');
          break;
      }
    } finally {
      setState(() {
        _busy = false;
        _status = _listening
            ? (_liveMode
                  ? 'Live режим: слушаю. Скажи "Жанарым ..."'
                  : 'Слушаю.')
            : 'Готов. Нажми "Голос".';
      });
    }
  }

  // ========= Manual buttons (gallery/camera) =========

  Future<void> _pickFromGallery() async {
    if (_busy) return;
    final file = await _picker.pickImage(
      source: ImageSource.gallery,
      imageQuality: 85,
    );
    if (file == null) return;

    setState(() {
      _image = file;
      _status = 'Фото выбрано. Нажми "Описать" или скажи "Жанарым, опиши".';
      _result = '';
    });
    await _speak('Фото выбрано. Нажми описать.');
  }

  Future<void> _takePhoto() async {
    if (_busy) return;
    final file = await _picker.pickImage(
      source: ImageSource.camera,
      imageQuality: 85,
    );
    if (file == null) return;

    setState(() {
      _image = file;
      _status = 'Фото сделано. Нажми "Описать" или скажи "Жанарым, опиши".';
      _result = '';
    });
    await _speak('Фото сделано. Нажми описать.');
  }

  // ========= Voice-triggered actions =========

  /// Голосом: "Жанарым, опиши" — если фото нет, делаем снимок и отправляем в OpenAI Vision.
  Future<void> _voiceDescribeWithOpenAI() async {
    await _speak('Окей. Сделаю снимок и опишу.');

    // Если фото не выбрано — снимаем.
    XFile? img = _image;
    img ??= await _picker.pickImage(
      source: ImageSource.camera,
      imageQuality: 85,
    );
    if (img == null) {
      await _speak('Не получилось сделать фото.');
      return;
    }

    setState(() {
      _image = img;
      _result = '';
      _status = 'Анализирую изображение...';
    });

    final bytes = await File(img.path).readAsBytes();
    final base64Image = base64Encode(bytes);

    final prompt = _buildJanarymPrompt();
    final text = await _callOpenAIResponsesVision(
      apiKey: OPENAI_API_KEY,
      model: OPENAI_MODEL,
      base64Image: base64Image,
      prompt: prompt,
    );

    setState(() {
      _result = text;
      _status = 'Готово.';
    });
    await _speak(text);
  }

  /// Голосом: "Жанарым, что впереди/слева/справа/сзади"
  /// MVP: делаем один снимок камерой -> отправляем на YOLO сервер -> короткая озвучка объектов.
  Future<void> _voiceYoloDirection(String directionRu) async {
    if (YOLO_SERVER_URL.trim().isEmpty) {
      await _speak('YOLO сервер не настроен.');
      return;
    }

    await _speak('Секунду. Смотрю $directionRu.');

    final img = await _picker.pickImage(
      source: ImageSource.camera,
      imageQuality: 80,
    );
    if (img == null) {
      await _speak('Не получилось сделать фото.');
      return;
    }

    setState(() {
      _image = img;
      _result = '';
      _status = 'YOLO анализ: $directionRu...';
    });

    final bytes = await File(img.path).readAsBytes();
    final detections = await _yolo.detectJpeg(bytes);

    if (detections.isEmpty) {
      final text = 'Я не вижу объектов $directionRu.';
      setState(() => _result = text);
      await _speak(text);
      return;
    }

    // Берём топ объектов по уверенности
    detections.sort((a, b) => b.conf.compareTo(a.conf));
    final top = detections.take(6).where((d) => d.conf >= 0.35).toList();

    final labels = <String>[];
    for (final d in top) {
      labels.add(d.label);
    }

    final summary = labels.isEmpty
        ? 'Я не уверен, что там есть объекты.'
        : 'С $directionRu я вижу: ${labels.toSet().join(', ')}.';

    setState(() => _result = summary);
    await _speak(summary);
  }

  // ========= Utilities =========

  String _buildJanarymPrompt() {
    return '''
Ты — Janarym, ассистент для незрячего пользователя.
Опиши изображение так, чтобы человек мог понять ситуацию и действовать.

Правила:
1) Начни с 1–2 предложений "что в целом происходит".
2) Затем списком: главные объекты, их расположение (слева/справа/по центру/вдалеке).
3) Если виден текст — перепиши текст точно.
4) Если есть потенциальные риски (ступеньки, машины, огонь, острые предметы) — скажи явно.
5) Если это документ/меню/упаковка — выдели ключевые поля/цены/состав/срок.
6) Заверши 1–2 уточняющими вопросами.

Тон: спокойный, конкретный, без воды.
Язык: русский.
''';
  }

  Future<void> _clear() async {
    if (_busy) return;
    setState(() {
      _image = null;
      _result = '';
      _lastText = '';
      _status = 'Готов. Нажми "Голос" и скажи "Жанарым ..."';
    });
    await _speak('Очищено. Готов к работе.');
  }

  @override
  Widget build(BuildContext context) {
    final img = _image;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Janarym'),
        actions: [
          IconButton(
            tooltip: 'Очистить',
            onPressed: _clear,
            icon: const Icon(Icons.delete_outline),
          ),
          const SizedBox(width: 4),
        ],
      ),
      body: Semantics(
        label: 'Экран Janarym. Live голосовые команды и описание изображений.',
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            children: [
              _StatusCard(
                status: _status,
                lastText: _lastText,
                busy: _busy,
                listening: _listening,
                liveMode: _liveMode,
              ),
              const SizedBox(height: 12),

              Expanded(
                child: Container(
                  width: double.infinity,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: Colors.white24),
                  ),
                  child: img == null
                      ? const Center(
                          child: Text(
                            'Нет фото\n(можно голосом: "Жанарым, опиши")',
                            textAlign: TextAlign.center,
                          ),
                        )
                      : ClipRRect(
                          borderRadius: BorderRadius.circular(16),
                          child: Image.file(File(img.path), fit: BoxFit.cover),
                        ),
                ),
              ),

              const SizedBox(height: 12),

              Row(
                children: [
                  Expanded(
                    child: _BigButton(
                      icon: _listening ? Icons.mic_off : Icons.mic,
                      text: _listening ? 'Стоп' : 'Голос',
                      onPressed: _toggleListening,
                      enabled: !_busy,
                      semanticLabel: _listening
                          ? 'Остановить прослушивание'
                          : 'Начать прослушивание',
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: _BigButton(
                      icon: Icons.photo_library_outlined,
                      text: 'Галерея',
                      onPressed: _pickFromGallery,
                      enabled: !_busy,
                      semanticLabel: 'Выбрать фото из галереи',
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  Expanded(
                    child: _BigButton(
                      icon: Icons.photo_camera_outlined,
                      text: 'Камера',
                      onPressed: _takePhoto,
                      enabled: !_busy,
                      semanticLabel: 'Сделать фото камерой',
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: _BigButton(
                      icon: Icons.visibility_outlined,
                      text: 'Описать',
                      onPressed: _voiceDescribeWithOpenAI,
                      enabled: !_busy,
                      semanticLabel: 'Описать изображение через OpenAI',
                    ),
                  ),
                ],
              ),

              const SizedBox(height: 12),

              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: Colors.white10,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: Colors.white24),
                ),
                child: SingleChildScrollView(
                  child: Text(
                    _result.isEmpty ? 'Результат появится здесь.' : _result,
                    style: const TextStyle(fontSize: 16, height: 1.35),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _StatusCard extends StatelessWidget {
  final String status;
  final String lastText;
  final bool busy;
  final bool listening;
  final bool liveMode;

  const _StatusCard({
    required this.status,
    required this.lastText,
    required this.busy,
    required this.listening,
    required this.liveMode,
  });

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: 'Статус: $status',
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: Colors.white10,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: Colors.white24),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              status,
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 6),
            Wrap(
              spacing: 8,
              runSpacing: 6,
              children: [
                _Chip(text: busy ? 'BUSY' : 'IDLE'),
                _Chip(text: listening ? 'LISTENING' : 'NOT LISTENING'),
                _Chip(text: liveMode ? 'LIVE: ON' : 'LIVE: OFF'),
                if (lastText.isNotEmpty) _Chip(text: 'STT: $lastText'),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _Chip extends StatelessWidget {
  final String text;
  const _Chip({required this.text});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: Colors.white12,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: Colors.white24),
      ),
      child: Text(text, style: const TextStyle(fontSize: 12)),
    );
  }
}

class _BigButton extends StatelessWidget {
  final IconData icon;
  final String text;
  final VoidCallback onPressed;
  final bool enabled;
  final String semanticLabel;

  const _BigButton({
    required this.icon,
    required this.text,
    required this.onPressed,
    required this.enabled,
    required this.semanticLabel,
  });

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: semanticLabel,
      child: SizedBox(
        height: 56,
        child: FilledButton.icon(
          onPressed: enabled ? onPressed : null,
          icon: Icon(icon),
          label: Text(text, style: const TextStyle(fontSize: 18)),
        ),
      ),
    );
  }
}

/// ======================
/// OpenAI call (Responses API) with base64 image
/// ======================
Future<String> _callOpenAIResponsesVision({
  required String apiKey,
  required String model,
  required String base64Image,
  required String prompt,
}) async {
  if (apiKey.isEmpty || apiKey.contains('PASTE_YOUR')) {
    throw Exception('OPENAI_API_KEY не задан');
  }

  final uri = Uri.parse('https://api.openai.com/v1/responses');

  final body = {
    "model": model,
    "input": [
      {
        "role": "user",
        "content": [
          {"type": "input_text", "text": prompt},
          {
            "type": "input_image",
            "image_url": "data:image/jpeg;base64,$base64Image",
          },
        ],
      },
    ],
    "max_output_tokens": 450,
  };

  final res = await http.post(
    uri,
    headers: {
      HttpHeaders.authorizationHeader: 'Bearer $apiKey',
      HttpHeaders.contentTypeHeader: 'application/json',
    },
    body: jsonEncode(body),
  );

  if (res.statusCode < 200 || res.statusCode >= 300) {
    throw Exception('OpenAI HTTP ${res.statusCode}: ${res.body}');
  }

  final decoded = jsonDecode(res.body);

  final outputText = decoded["output_text"];
  if (outputText is String && outputText.trim().isNotEmpty) {
    return outputText.trim();
  }

  final output = decoded["output"];
  if (output is List) {
    final buffer = StringBuffer();
    for (final item in output) {
      final content = item["content"];
      if (content is List) {
        for (final c in content) {
          if (c["type"] == "output_text" && c["text"] is String) {
            buffer.writeln(c["text"]);
          }
        }
      }
    }
    final t = buffer.toString().trim();
    if (t.isNotEmpty) return t;
  }

  return 'Не удалось извлечь текст ответа.';
}
