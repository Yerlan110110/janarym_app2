import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:image_picker/image_picker.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:speech_to_text/speech_to_text.dart' as stt;
import 'package:permission_handler/permission_handler.dart';

import 'core/assistant_engine.dart';
import 'core/live_router.dart';
import 'vision/frame_provider.dart';
import 'vision/openai_vision.dart';
import 'vision/yolo_client.dart';

/// ======================
/// Janarym MVP (Flutter)
/// Live STT ("Жанарым ... команда") + OpenAI Vision + (опционально) YOLO server
/// ======================

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await dotenv.load(fileName: '.env');
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
  static const String _openAiModel = 'gpt-4.1-mini';
  // ====================

  final _picker = ImagePicker();
  final _tts = FlutterTts();
  final _stt = stt.SpeechToText();

  final LiveRouter _router = LiveRouter();
  final FrameProvider _frameProvider = FrameProvider();
  late final AssistantEngine _engine;

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
    _initEngine();
    _initPermissions().then((_) => _initFrameProvider());
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

  void _initEngine() {
    final apiKey = dotenv.get('OPENAI_API_KEY', fallback: '');
    final yoloUrl = dotenv.get('YOLO_SERVER_URL', fallback: '').trim();

    final visionClient = OpenAiVisionClient(
      apiKey: apiKey,
      model: _openAiModel,
    );
    final yoloClient = YoloClient(yoloUrl);
    _engine = AssistantEngine(
      visionClient: visionClient,
      yoloClient: yoloClient,
      speak: _speak,
      getLatestFrameJpeg: _getLatestFrameJpeg,
      capturePhotoJpegFallback: _capturePhotoJpegFallback,
      setTtsVolume: _setTtsVolume,
    );
  }

  Future<void> _initFrameProvider() async {
    try {
      await _frameProvider.init();
      await _frameProvider.start();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _status = 'Camera init error: $e';
      });
    }
  }

  Future<void> _speak(String text) async {
    final t = text.trim();
    if (t.isEmpty) return;
    await _tts.stop();
    await _tts.speak(t);
  }

  Future<void> _setTtsVolume(double volume) async {
    await _tts.setVolume(volume);
  }

  Future<Uint8List?> _getLatestFrameJpeg() async {
    return _frameProvider.latestJpeg;
  }

  Future<T> _withFramePause<T>(Future<T> Function() action) async {
    final wasStreaming = _frameProvider.isStreaming;
    if (wasStreaming) {
      await _frameProvider.stop();
    }
    try {
      return await action();
    } finally {
      if (wasStreaming) {
        await _frameProvider.start();
      }
    }
  }

  Future<Uint8List?> _capturePhotoJpegFallback() async {
    return _withFramePause(() async {
      final file = await _picker.pickImage(
        source: ImageSource.camera,
        imageQuality: 85,
      );
      if (file == null) return null;

      final bytes = await File(file.path).readAsBytes();
      if (!mounted) return bytes;

      setState(() {
        _image = file;
        _result = '';
        _status = 'Фото сделано. Нажми "Описать" или скажи "Жанарым, опиши".';
      });

      return bytes;
    });
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
      listenOptions: stt.SpeechListenOptions(
        listenMode: stt.ListenMode.confirmation,
      ),
      onResult: (res) async {
        if (!_listening) return;
        if (_busy) return;

        final text = res.recognizedWords.trim();
        if (text.isEmpty) return;

        setState(() => _lastText = text);

        // Парсим команды только если есть wake word "Жанарым..."
        final cmd = _router.parse(text);
        if (cmd == null) return;

        setState(() {
          _busy = true;
          _status = 'Команда: ${cmd.intent}';
        });

        try {
          if (cmd.intent == 'live_on') {
            setState(() {
              _liveMode = true;
              _status = 'Live режим включён. Скажи "Жанарым ..."';
            });
            await _speak('Лайв режим включён.');
          } else if (cmd.intent == 'live_off') {
            setState(() {
              _liveMode = false;
              _status = 'Live режим выключен.';
            });
            await _speak('Лайв режим выключен.');
          } else {
            final result = await _engine.handleIntent(cmd.intent);
            if (result != null && mounted) {
              setState(() {
                _result = result;
              });
            }
          }
        } finally {
          if (mounted) {
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
      },
    );
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
    final file = await _withFramePause(() async {
      return _picker.pickImage(
        source: ImageSource.camera,
        imageQuality: 85,
      );
    });
    if (file == null) return;

    setState(() {
      _image = file;
      _status = 'Фото сделано. Нажми "Описать" или скажи "Жанарым, опиши".';
      _result = '';
    });
    await _speak('Фото сделано. Нажми описать.');
  }

  // ========= Manual actions =========

  Future<void> _describeSelectedImage() async {
    if (_busy) return;
    await _speak('Окей. Сделаю снимок и опишу.');

    XFile? img = _image;
    img ??= await _withFramePause(() async {
      return _picker.pickImage(
        source: ImageSource.camera,
        imageQuality: 85,
      );
    });
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
    final text = await _engine.describeJpegBytes(bytes, detailed: false);

    if (!mounted) return;
    setState(() {
      _result = text;
      _status = 'Готово.';
    });
  }

  // ========= Utilities =========

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
  void dispose() {
    _stt.stop();
    _tts.stop();
    _frameProvider.dispose();
    super.dispose();
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
                      onPressed: _describeSelectedImage,
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
