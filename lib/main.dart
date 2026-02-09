import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:image_picker/image_picker.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:permission_handler/permission_handler.dart';

import 'core/assistant_engine.dart';
import 'core/live_router.dart';
import 'vision/frame_provider.dart';
import 'vision/openai_vision.dart';
import 'vision/yolo_client.dart';
import 'voice/speech_engine.dart';

/// ======================
/// Janarym MVP (Flutter)
/// Live STT ("Жанарым ... команда") + OpenAI Vision + (опционально) YOLO server
/// ======================

const String _openAiApiKeyEnvName = 'OPENAI' '_API_KEY';
const String _yoloServerUrlEnvName = 'YOLO' '_SERVER_URL';
const String _missingOpenAiKeyMessage =
    'Нет .env, добавь OPENAI_API_KEY';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await dotenv.load(fileName: ".env", isOptional: true);
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
  final SpeechEngine _speechEngine = SpeechEngine();
  StreamSubscription<SpeechEvent>? _speechSub;

  final LiveRouter _router = LiveRouter();
  final FrameProvider _frameProvider = FrameProvider();
  AssistantEngine? _engine;

  bool _listening = false; // микрофон слушает
  bool _busy = false; // выполняется действие (не слушаем/не принимаем)
  bool _liveMode = true; // "как алиса": слушаем и реагируем на "Жанарым ..."

  String _status = 'Готов. Нажми "Голос" и говори: "Жанарым, что впереди"';
  String _lastText = '';
  String _liveSpeech = '';
  String _finalSpeech = '';
  String _result = '';
  bool _sttReady = false;
  bool _startingStt = false;
  bool _sttAvailable = false;
  DateTime? _sttStartedAt;
  String _selectedLocale = '—';
  String _sttStatus = 'idle';
  String _sttError = '';
  String _sttDebug = '';
  double _soundLevel = 0.0;
  String _engineName = '—';
  bool _voskModelReady = false;
  String _voskModelPath = '';
  double _voskDownloadProgress = 0.0;
  int _voskSampleRate = 0;
  String _voskError = '';
  String _micPermission = 'unknown';
  String _sttWarningMessage = '';
  Timer? _sttAutoStopTimer;
  bool _showDebug = false;
  bool _openAiReady = false;
  String _envError = '';
  bool _processCommands = true;

  XFile? _image; // последнее фото (галерея/камера)

  @override
  void initState() {
    super.initState();
    _initTts();
    _initEngine();
    _initPermissions().then((_) => _initFrameProvider());
    _speechSub = _speechEngine.events.listen(_handleSpeechEvent);
  }

  Future<void> _initPermissions() async {
    await [
      Permission.camera,
      Permission.photos, // iOS
      Permission.storage, // Android legacy
    ].request();
    await _updateMicPermissionStatus();
  }

  void _setStatus(String status) {
    if (!mounted) return;
    setState(() => _status = status);
  }

  void _handleSpeechEvent(SpeechEvent event) {
    if (!mounted) return;
    switch (event.type) {
      case SpeechEventType.partial:
        setState(() {
          _liveSpeech = event.text;
        });
        break;
      case SpeechEventType.finalResult:
        _handleFinalSpeech(event.text);
        break;
      case SpeechEventType.status:
        setState(() {
          _sttStatus = event.text;
        });
        break;
      case SpeechEventType.error:
        setState(() {
          _sttError = event.text;
          _sttWarningMessage = event.text;
          _status = event.text;
        });
        break;
      case SpeechEventType.progress:
        setState(() {
          _voskDownloadProgress = event.progress ?? 0.0;
        });
        break;
    }
    _syncSttState();
  }

  void _syncSttState() {
    if (!mounted) return;
    setState(() {
      _sttReady = _speechEngine.isReady;
      _sttAvailable = _speechEngine.isReady;
      _sttStatus =
          _speechEngine.lastStatus.isEmpty ? 'idle' : _speechEngine.lastStatus;
      _sttError = _speechEngine.lastError;
      _selectedLocale = _speechEngine.selectedLocale.isEmpty
          ? '—'
          : _speechEngine.selectedLocale;
      _soundLevel = _speechEngine.soundLevel;
      _engineName = _speechEngine.engineName;
      _sttDebug = _speechEngine.localesSummary;
      _voskModelReady = _speechEngine.voskModelReady;
      _voskModelPath = _speechEngine.voskModelPath;
      _voskDownloadProgress = _speechEngine.voskDownloadProgress;
      _voskSampleRate = _speechEngine.voskSampleRate;
      _voskError = _speechEngine.voskLastError;
      _listening = _speechEngine.isListening;
    });
  }

  Future<bool> _ensureSttInitialized({bool force = false}) async {
    if (_sttReady && !force) return true;
    _sttWarningMessage = '';
    final available = await _speechEngine.prepare(
      preferredLocale: 'ru-RU',
      force: force,
    );
    _syncSttState();
    if (!available) {
      _setStatus('STT недоступно (движок отключён или отсутствует).');
      _sttWarningMessage =
          'Распознавание речи недоступно на этом устройстве.';
    }
    return available;
  }

  String _permissionLabel(PermissionStatus status) {
    if (status.isGranted) return 'granted';
    if (status.isDenied) return 'denied';
    if (status.isPermanentlyDenied) return 'permanentlyDenied';
    if (status.isRestricted) return 'restricted';
    if (status.isLimited) return 'limited';
    return 'unknown';
  }

  Future<void> _updateMicPermissionStatus() async {
    final status = await Permission.microphone.status;
    if (!mounted) return;
    setState(() {
      _micPermission = _permissionLabel(status);
    });
  }

  Future<bool> _ensureMicPermission() async {
    final status = await Permission.microphone.status;
    if (mounted) {
      setState(() {
        _micPermission = _permissionLabel(status);
      });
    }
    if (status.isGranted) return true;

    final requested = await Permission.microphone.request();
    if (mounted) {
      setState(() {
        _micPermission = _permissionLabel(requested);
      });
    }
    if (requested.isGranted) return true;

    if (mounted) {
      setState(() {
        _status = 'Нет доступа к микрофону. Разрешите в настройках.';
        _sttError = 'Mic permission not granted.';
      });
    }
    await _speak('Нужен доступ к микрофону.');
    await openAppSettings();
    return false;
  }

  Future<void> _initTts() async {
    await _tts.setLanguage('ru-RU');
    await _tts.setSpeechRate(0.45);
    await _tts.setPitch(1.0);
  }

  void _initEngine() {
    final apiKeyFromEnv =
        dotenv.get(_openAiApiKeyEnvName, fallback: '').trim();
    const apiKeyFromDefine =
        String.fromEnvironment(_openAiApiKeyEnvName);
    final apiKey = apiKeyFromEnv.isNotEmpty
        ? apiKeyFromEnv
        : apiKeyFromDefine.trim();
    if (apiKey.isEmpty) {
      _envError = _missingOpenAiKeyMessage;
      _status = _missingOpenAiKeyMessage;
      _openAiReady = false;
      return;
    }
    final yoloFromEnv =
        dotenv.get(_yoloServerUrlEnvName, fallback: '').trim();
    const yoloFromDefine =
        String.fromEnvironment(_yoloServerUrlEnvName);
    final yoloUrl = yoloFromEnv.isNotEmpty
        ? yoloFromEnv
        : yoloFromDefine.trim();

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
    _openAiReady = true;
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
    if (_startingStt) {
      _setStatus('Запуск распознавания...');
      return;
    }
    if (_busy) {
      _setStatus('Занят. Подождите.');
      return;
    }

    if (_listening || _speechEngine.isListening) {
      await _stopListening(userInitiated: true);
      return;
    }

    setState(() {
      _startingStt = true;
      _status = 'Подготовка распознавания...';
      _sttWarningMessage = '';
    });

    try {
      final micOk = await _ensureMicPermission();
      if (!micOk) return;

      await _tts.stop();
      await Future.delayed(const Duration(milliseconds: 250));

      final ready = await _ensureSttInitialized();
      if (!ready) return;

      await _speechEngine.stopListening();
      await Future.delayed(const Duration(milliseconds: 100));

      if (!mounted) return;
      setState(() {
        _sttStartedAt = DateTime.now();
        _status = 'Слушаю...';
      });

      await _startListening(processCommands: true);
    } finally {
      if (mounted) {
        setState(() {
          _startingStt = false;
        });
      }
    }
  }

  Future<void> _startListening({
    required bool processCommands,
    Duration? autoStop,
  }) async {
    _sttAutoStopTimer?.cancel();
    if (!mounted) return;
    setState(() {
      _listening = true;
      _liveSpeech = '';
      _finalSpeech = '';
      _sttError = '';
      _sttWarningMessage = '';
      _sttStartedAt = DateTime.now();
      _sttStatus = 'listening';
      _soundLevel = 0.0;
      _processCommands = processCommands;
      _status = processCommands ? 'Слушаю...' : 'Проверка микрофона...';
    });

    final ok = await _speechEngine.startListening(
      preferredLocale: 'ru-RU',
    );
    _syncSttState();
    if (ok && mounted) {
      final engineLabel =
          _speechEngine.engineName.isEmpty ? '' : ' (${_speechEngine.engineName})';
      setState(() {
        _status = processCommands
            ? 'Слушаю$engineLabel...'
            : 'Проверка микрофона$engineLabel...';
      });
    } else if (!ok && mounted) {
      setState(() {
        _listening = false;
        _status = _speechEngine.lastError.isNotEmpty
            ? _speechEngine.lastError
            : 'Не удалось начать прослушивание.';
      });
    }

    if (autoStop != null) {
      _sttAutoStopTimer = Timer(autoStop, () async {
        if (_listening) {
          await _stopListening();
          if (!mounted) return;
          setState(() {
            _status = 'Проверка микрофона завершена.';
          });
        }
      });
    }
  }

  Future<void> _handleFinalSpeech(String text) async {
    if (!mounted) return;
    final cleaned = text.trim();
    if (cleaned.isEmpty) {
      setState(() {
        _status = 'Не распознано';
        _result = 'Не распознано';
      });
      return;
    }

    setState(() {
      _finalSpeech = cleaned;
      _lastText = cleaned;
      _status = 'User said: $cleaned';
    });

    if (!_processCommands || _busy) return;

    final cmd = _router.parse(cleaned);
    if (cmd == null) {
      setState(() {
        _status = 'Не распознано';
        _result = 'User said: $cleaned\nAssistant: Не распознано';
      });
      return;
    }

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
        setState(() {
          _result = 'User said: $cleaned\nAssistant: Лайв режим включён.';
        });
      } else if (cmd.intent == 'live_off') {
        setState(() {
          _liveMode = false;
          _status = 'Live режим выключен.';
        });
        await _speak('Лайв режим выключен.');
        setState(() {
          _result = 'User said: $cleaned\nAssistant: Лайв режим выключен.';
        });
      } else {
        final engine = _engine;
        if (engine == null) {
          setState(() {
            _status = _missingOpenAiKeyMessage;
            _sttWarningMessage = _missingOpenAiKeyMessage;
          });
          return;
        }
        final result = await engine.handleIntent(cmd.intent);
        if (mounted) {
          final assistantText =
              (result ?? engine.lastResult).trim().isEmpty
                  ? 'Готово.'
                  : (result ?? engine.lastResult).trim();
          setState(() {
            _result = 'User said: $cleaned\nAssistant: $assistantText';
          });
        }
      }
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _status = _listening
              ? 'Слушаю...'
              : 'Готов. Нажми "Голос".';
        });
      }
    }
  }

  Future<void> _stopListening({bool userInitiated = false}) async {
    _sttAutoStopTimer?.cancel();
    await _speechEngine.stopListening();
    if (!mounted) return;
    setState(() {
      _listening = false;
      _sttStartedAt = null;
      _sttStatus = 'idle';
      _soundLevel = 0.0;
      if (userInitiated) {
        _status = 'Остановлено.';
      }
    });
  }

  Future<void> _micCheck() async {
    if (_startingStt) {
      _setStatus('Запуск распознавания...');
      return;
    }
    if (_busy) {
      _setStatus('Занят. Подождите.');
      return;
    }
    if (_listening || _speechEngine.isListening) {
      await _stopListening(userInitiated: true);
      return;
    }
    final micOk = await _ensureMicPermission();
    if (!micOk) return;
    await _tts.stop();
    await Future.delayed(const Duration(milliseconds: 250));
    final ready = await _ensureSttInitialized();
    if (!ready) return;
    await _startListening(
      processCommands: false,
      autoStop: const Duration(seconds: 5),
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
    final engine = _engine;
    if (engine == null) {
      _setStatus(_missingOpenAiKeyMessage);
      if (mounted) {
        setState(() {
          _envError = _missingOpenAiKeyMessage;
        });
      }
      await _speak('Нужен ключ OpenAI.');
      return;
    }
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
    final text = await engine.describeJpegBytes(bytes, detailed: false);

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
      _liveSpeech = '';
      _finalSpeech = '';
      _sttWarningMessage = '';
      _sttError = '';
      _sttStatus = _sttReady ? 'ready' : 'idle';
      _selectedLocale = '—';
      _soundLevel = 0.0;
      _sttStartedAt = null;
      _status = 'Готов. Нажми "Голос" и скажи "Жанарым ..."';
    });
    await _speak('Очищено. Готов к работе.');
  }

  @override
  void dispose() {
    _sttAutoStopTimer?.cancel();
    _speechSub?.cancel();
    _speechEngine.stopListening();
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
          if (kDebugMode)
            IconButton(
              tooltip: _showDebug ? 'Скрыть Debug' : 'Показать Debug',
              onPressed: () {
                setState(() {
                  _showDebug = !_showDebug;
                });
              },
              icon: Icon(
                _showDebug ? Icons.bug_report : Icons.bug_report_outlined,
              ),
            ),
          IconButton(
            tooltip: 'Очистить',
            onPressed: _clear,
            icon: const Icon(Icons.delete_outline),
          ),
          const SizedBox(width: 4),
        ],
      ),
      body: SafeArea(
        child: Semantics(
          label: 'Экран Janarym. Live голосовые команды и описание изображений.',
          child: Column(
            children: [
              Expanded(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      _StatusCard(
                        status: _status,
                        lastText: _lastText,
                        busy: _busy,
                        listening: _listening,
                        liveMode: _liveMode,
                      ),
                      const SizedBox(height: 12),

                      Semantics(
                        label: 'Распознанная речь',
                        value: _liveSpeech.isEmpty ? '…' : _liveSpeech,
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
                              const Text(
                                'Вы говорите:',
                                style: TextStyle(
                                  fontSize: 14,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              const SizedBox(height: 6),
                              Text(
                                _liveSpeech.isEmpty ? '…' : _liveSpeech,
                                style: const TextStyle(
                                  fontSize: 16,
                                  height: 1.35,
                                ),
                                softWrap: true,
                              ),
                            ],
                          ),
                        ),
                      ),

                      const SizedBox(height: 12),

                      if (kDebugMode && _showDebug)
                        _SpeechDebugCard(
                          micPermission: _micPermission,
                          engineName: _engineName,
                          sttReady: _sttReady,
                          sttAvailable: _sttAvailable,
                          startingStt: _startingStt,
                          sttStatus: _sttStatus,
                          listening: _listening,
                          sttError: _sttError,
                          sttDebug: _sttDebug,
                          sttStartedAt: _sttStartedAt,
                          selectedLocale: _selectedLocale,
                          soundLevel: _soundLevel,
                          liveSpeech: _liveSpeech,
                          finalSpeech: _finalSpeech,
                          openAiReady: _openAiReady,
                          voskModelReady: _voskModelReady,
                          voskModelPath: _voskModelPath,
                          voskDownloadProgress: _voskDownloadProgress,
                          voskSampleRate: _voskSampleRate,
                          voskError: _voskError,
                        ),

                      if (kDebugMode && _showDebug)
                        const SizedBox(height: 12),

                      if (_envError.isNotEmpty)
                        Container(
                          width: double.infinity,
                          padding: const EdgeInsets.all(14),
                          decoration: BoxDecoration(
                            color: Colors.redAccent.withValues(alpha: 0.15),
                            borderRadius: BorderRadius.circular(16),
                            border: Border.all(color: Colors.redAccent),
                          ),
                          child: Text(
                            _envError,
                            style: const TextStyle(fontSize: 14, height: 1.35),
                            softWrap: true,
                          ),
                        ),

                      if (_envError.isNotEmpty)
                        const SizedBox(height: 12),

                      if (_sttWarningMessage.isNotEmpty)
                        Container(
                          width: double.infinity,
                          padding: const EdgeInsets.all(14),
                          decoration: BoxDecoration(
                            color: Colors.redAccent.withValues(alpha: 0.15),
                            borderRadius: BorderRadius.circular(16),
                            border: Border.all(color: Colors.redAccent),
                          ),
                          child: Text(
                            _sttWarningMessage,
                            style: const TextStyle(fontSize: 14, height: 1.35),
                            softWrap: true,
                          ),
                        ),

                      if (_sttWarningMessage.isNotEmpty)
                        const SizedBox(height: 12),

                      AspectRatio(
                        aspectRatio: 4 / 3,
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
                                  child: Image.file(
                                    File(img.path),
                                    fit: BoxFit.cover,
                                  ),
                                ),
                        ),
                      ),

                      const SizedBox(height: 12),

                      SizedBox(
                        width: double.infinity,
                        child: OutlinedButton.icon(
                          onPressed: _busy ? null : _micCheck,
                          icon: const Icon(Icons.hearing),
                          label: const Text('Проверить микрофон'),
                        ),
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
                        child: Text(
                          _result.isEmpty ? 'Результат появится здесь.' : _result,
                          style: const TextStyle(fontSize: 16, height: 1.35),
                          softWrap: true,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
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

class _SpeechDebugCard extends StatelessWidget {
  final String micPermission;
  final String engineName;
  final bool sttReady;
  final bool sttAvailable;
  final bool startingStt;
  final String sttStatus;
  final bool listening;
  final String sttError;
  final String sttDebug;
  final DateTime? sttStartedAt;
  final String selectedLocale;
  final double soundLevel;
  final String liveSpeech;
  final String finalSpeech;
  final bool openAiReady;
  final bool voskModelReady;
  final String voskModelPath;
  final double voskDownloadProgress;
  final int voskSampleRate;
  final String voskError;

  const _SpeechDebugCard({
    required this.micPermission,
    required this.engineName,
    required this.sttReady,
    required this.sttAvailable,
    required this.startingStt,
    required this.sttStatus,
    required this.listening,
    required this.sttError,
    required this.sttDebug,
    required this.sttStartedAt,
    required this.selectedLocale,
    required this.soundLevel,
    required this.liveSpeech,
    required this.finalSpeech,
    required this.openAiReady,
    required this.voskModelReady,
    required this.voskModelPath,
    required this.voskDownloadProgress,
    required this.voskSampleRate,
    required this.voskError,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white10,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.white24),
      ),
      child: ExpansionTile(
        tilePadding: EdgeInsets.zero,
        childrenPadding: EdgeInsets.zero,
        initiallyExpanded: false,
        title: const Text(
          'Speech Debug',
          style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
        ),
        children: [
          _DebugLine(label: 'Mic permission', value: micPermission),
          _DebugLine(label: 'Engine', value: engineName),
          _DebugLine(label: 'STT available', value: '$sttAvailable'),
          _DebugLine(label: 'STT ready', value: '$sttReady'),
          _DebugLine(label: 'OpenAI ready', value: '$openAiReady'),
          _DebugLine(label: 'Starting STT', value: '$startingStt'),
          _DebugLine(label: 'Listening', value: '$listening'),
          _DebugLine(
            label: 'STT status',
            value: sttStatus.isEmpty ? '—' : sttStatus,
          ),
          _DebugLine(
            label: 'STT error',
            value: sttError.isEmpty ? '—' : sttError,
            maxLines: 3,
          ),
          _DebugLine(
            label: 'STT debug',
            value: sttDebug.isEmpty ? '—' : sttDebug,
            maxLines: 3,
          ),
          _DebugLine(
            label: 'Started',
            value: _formatStartedAt(sttStartedAt),
          ),
          _DebugLine(label: 'Selected locale', value: selectedLocale),
          _DebugLine(
            label: 'Sound level',
            value: soundLevel.toStringAsFixed(2),
          ),
          _DebugLine(label: 'Vosk model ready', value: '$voskModelReady'),
          _DebugLine(
            label: 'Vosk model path',
            value: voskModelPath.isEmpty ? '—' : voskModelPath,
            maxLines: 2,
          ),
          _DebugLine(
            label: 'Vosk download',
            value: _formatProgress(voskDownloadProgress),
          ),
          _DebugLine(
            label: 'Vosk sampleRate',
            value: voskSampleRate == 0 ? '—' : '$voskSampleRate',
          ),
          _DebugLine(
            label: 'Vosk error',
            value: voskError.isEmpty ? '—' : voskError,
            maxLines: 3,
          ),
          _DebugLine(
            label: 'Live words',
            value: liveSpeech.isEmpty ? '—' : liveSpeech,
            maxLines: 3,
          ),
          _DebugLine(
            label: 'Final words',
            value: finalSpeech.isEmpty ? '—' : finalSpeech,
            maxLines: 3,
          ),
        ],
      ),
    );
  }

  String _formatStartedAt(DateTime? dt) {
    if (dt == null) return '—';
    final diff = DateTime.now().difference(dt);
    final seconds = diff.inSeconds;
    if (seconds < 1) return 'now';
    return '${seconds}s ago';
  }

  String _formatProgress(double progress) {
    if (progress <= 0) return '—';
    final pct = (progress * 100).clamp(0, 100).toStringAsFixed(0);
    return '$pct%';
  }

}

class _DebugLine extends StatelessWidget {
  final String label;
  final String value;
  final int maxLines;

  const _DebugLine({
    required this.label,
    required this.value,
    this.maxLines = 2,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Text(
        '$label: $value',
        maxLines: maxLines,
        overflow: TextOverflow.ellipsis,
        softWrap: true,
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
