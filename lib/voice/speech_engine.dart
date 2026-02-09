import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';
import 'package:speech_to_text/speech_to_text.dart' as stt;
import 'package:vosk_flutter_service/vosk_flutter.dart';

enum SpeechEventType { partial, finalResult, status, error, progress }

class SpeechEvent {
  final SpeechEventType type;
  final String text;
  final double? progress;

  const SpeechEvent({
    required this.type,
    required this.text,
    this.progress,
  });
}

class SpeechEngine {
  final _controller = StreamController<SpeechEvent>.broadcast();
  final _vosk = _VoskEngine();
  final _system = _SystemEngine();

  _BaseEngine? _active;

  Stream<SpeechEvent> get events => _controller.stream;

  String get engineName => _active?.name ?? '—';
  bool get isReady => _active?.isReady ?? false;
  bool get isListening => _active?.isListening ?? false;
  String get lastError => _active?.lastError ?? '';
  String get lastStatus => _active?.lastStatus ?? 'idle';
  String get selectedLocale => _active?.selectedLocale ?? '';
  double get soundLevel => _active?.soundLevel ?? 0.0;

  bool get voskModelReady => _vosk.modelReady;
  String get voskModelPath => _vosk.modelPath;
  double get voskDownloadProgress => _vosk.downloadProgress;
  int get voskSampleRate => _vosk.sampleRate;
  String get voskLastError => _vosk.lastError;

  String get localesSummary => _system.localesSummary;

  void _emit(SpeechEvent event) {
    if (_controller.isClosed) return;
    _controller.add(event);
  }

  Future<bool> prepare({
    String? preferredLocale,
    bool force = false,
  }) async {
    final voskReady = await _vosk.init(
      force: force,
      onProgress: (p) => _emit(
        SpeechEvent(type: SpeechEventType.progress, text: 'vosk', progress: p),
      ),
      onStatus: (s) => _emit(
        SpeechEvent(type: SpeechEventType.status, text: s),
      ),
      onError: (e) => _emit(
        SpeechEvent(type: SpeechEventType.error, text: e),
      ),
    );

    if (voskReady) {
      _active = _vosk;
      return true;
    }

    final systemReady = await _system.init(
      force: force,
      preferredLocale: preferredLocale,
      onStatus: (s) => _emit(
        SpeechEvent(type: SpeechEventType.status, text: s),
      ),
      onError: (e) => _emit(
        SpeechEvent(type: SpeechEventType.error, text: e),
      ),
    );
    if (systemReady) {
      _active = _system;
      return true;
    }

    _emit(
      const SpeechEvent(
        type: SpeechEventType.error,
        text: 'System STT не стартует. Проверьте Google Speech Services.',
      ),
    );
    return false;
  }

  Future<bool> startListening({String? preferredLocale}) async {
    final ready = await prepare(preferredLocale: preferredLocale);
    if (!ready || _active == null) return false;

    final ok = await _active!.startListening(
      preferredLocale: preferredLocale,
      onPartial: (text) => _emit(
        SpeechEvent(type: SpeechEventType.partial, text: text),
      ),
      onFinal: (text) => _emit(
        SpeechEvent(type: SpeechEventType.finalResult, text: text),
      ),
      onStatus: (s) => _emit(
        SpeechEvent(type: SpeechEventType.status, text: s),
      ),
      onError: (e) => _emit(
        SpeechEvent(type: SpeechEventType.error, text: e),
      ),
      onSoundLevel: (level) {
        // Sound level is handled through active engine state.
      },
    );

    if (!ok && _active == _vosk) {
      final systemReady = await _system.init(
        force: true,
        preferredLocale: preferredLocale,
        onStatus: (s) => _emit(
          SpeechEvent(type: SpeechEventType.status, text: s),
        ),
        onError: (e) => _emit(
          SpeechEvent(type: SpeechEventType.error, text: e),
        ),
      );
      if (systemReady) {
        _active = _system;
        return _active!.startListening(
          preferredLocale: preferredLocale,
          onPartial: (text) => _emit(
            SpeechEvent(type: SpeechEventType.partial, text: text),
          ),
          onFinal: (text) => _emit(
            SpeechEvent(type: SpeechEventType.finalResult, text: text),
          ),
          onStatus: (s) => _emit(
            SpeechEvent(type: SpeechEventType.status, text: s),
          ),
          onError: (e) => _emit(
            SpeechEvent(type: SpeechEventType.error, text: e),
          ),
          onSoundLevel: (level) {},
        );
      }
      _emit(
        const SpeechEvent(
          type: SpeechEventType.error,
          text: 'System STT не стартует. Проверьте Google Speech Services.',
        ),
      );
    }

    if (!ok && _active == _system) {
      _emit(
        SpeechEvent(
          type: SpeechEventType.error,
          text: _system.lastError.isNotEmpty
              ? 'System STT не стартует: ${_system.lastError}'
              : 'System STT не стартует. Проверьте Google Speech Services.',
        ),
      );
    }

    return ok;
  }

  Future<void> stopListening() async {
    await _active?.stop();
  }
}

abstract class _BaseEngine {
  String get name;
  bool get isReady;
  bool get isListening;
  String get lastError;
  String get lastStatus;
  String get selectedLocale;
  double get soundLevel;

  Future<bool> init({
    bool force = false,
    String? preferredLocale,
    void Function(String status)? onStatus,
    void Function(String error)? onError,
    void Function(double progress)? onProgress,
  });

  Future<bool> startListening({
    String? preferredLocale,
    required void Function(String) onPartial,
    required void Function(String) onFinal,
    required void Function(String) onStatus,
    required void Function(String) onError,
    required void Function(double) onSoundLevel,
  });

  Future<void> stop();
}

class _SystemEngine implements _BaseEngine {
  final stt.SpeechToText _stt = stt.SpeechToText();

  bool _ready = false;
  bool _listening = false;
  String _lastError = '';
  String _lastStatus = 'idle';
  String _selectedLocale = '';
  double _soundLevel = 0.0;

  String _systemLocale = '';
  List<stt.LocaleName> _locales = [];

  Timer? _antiStuckTimer;

  @override
  String get name => 'System';

  @override
  bool get isReady => _ready;

  @override
  bool get isListening => _listening;

  @override
  String get lastError => _lastError;

  @override
  String get lastStatus => _lastStatus;

  @override
  String get selectedLocale => _selectedLocale;

  @override
  double get soundLevel => _soundLevel;

  String get localesSummary {
    if (_locales.isEmpty) return 'locales: 0';
    final preview = _locales.take(4).map((e) => e.localeId).join(', ');
    final system = _systemLocale.isEmpty ? '—' : _systemLocale;
    return 'locales: ${_locales.length} [$preview] system: $system';
  }

  @override
  Future<bool> init({
    bool force = false,
    String? preferredLocale,
    void Function(String status)? onStatus,
    void Function(String error)? onError,
    void Function(double progress)? onProgress,
  }) async {
    if (_ready && !force) return true;

    _lastError = '';
    _lastStatus = 'initializing';
    onStatus?.call(_lastStatus);

    try {
      final ok = await _stt.initialize(
        debugLogging: true,
        onStatus: (s) {
          _lastStatus = s;
          onStatus?.call(s);
          if (s == stt.SpeechToText.doneStatus ||
              s == stt.SpeechToText.notListeningStatus) {
            _listening = false;
          }
        },
        onError: (e) {
          _lastError = '${e.errorMsg} (${e.permanent})';
          _lastStatus = 'error';
          _listening = false;
          onError?.call(_lastError);
        },
      );
      _ready = ok;
      if (!ok) {
        _lastError = 'System STT init failed';
        onError?.call(_lastError);
        return false;
      }

      final systemLocale = await _stt.systemLocale();
      _systemLocale = systemLocale?.localeId ?? '';
      _locales = await _stt.locales();
      _selectedLocale = _selectLocale(preferredLocale) ?? '';

      _lastStatus = 'ready';
      onStatus?.call(_lastStatus);
      return true;
    } catch (e) {
      _ready = false;
      _lastError = 'init error: $e';
      _lastStatus = 'error';
      onError?.call(_lastError);
      return false;
    }
  }

  @override
  Future<bool> startListening({
    String? preferredLocale,
    required void Function(String) onPartial,
    required void Function(String) onFinal,
    required void Function(String) onStatus,
    required void Function(String) onError,
    required void Function(double) onSoundLevel,
  }) async {
    if (!_ready) {
      onError('System STT не готов.');
      return false;
    }

    _selectedLocale = _selectLocale(preferredLocale) ?? '';
    _lastError = '';
    _lastStatus = 'listening';
    _listening = true;
    onStatus(_lastStatus);

    try {
      await _stt.listen(
        localeId: _selectedLocale.isEmpty ? null : _selectedLocale,
        listenOptions: stt.SpeechListenOptions(
          partialResults: true,
          cancelOnError: false,
          listenMode: stt.ListenMode.dictation,
        ),
        onResult: (res) {
          final words = res.recognizedWords;
          onPartial(words);
          if (res.finalResult) {
            onFinal(words);
          }
        },
        onSoundLevelChange: (level) {
          _soundLevel = level;
          onSoundLevel(level);
        },
      );
    } catch (e) {
      _lastError = 'listen error: $e';
      _lastStatus = 'error';
      _listening = false;
      onError(_lastError);
      return false;
    }

    _startAntiStuckTimer(onError: onError);
    return true;
  }

  void _startAntiStuckTimer({required void Function(String) onError}) {
    _antiStuckTimer?.cancel();
    _antiStuckTimer = Timer(const Duration(milliseconds: 2500), () async {
      if (!_listening) return;
      if (_soundLevel.abs() > 0.1) return;
      await stop();
      onError(
        'System STT не стартует. Проверьте Google Speech Services.',
      );
    });
  }

  String? _selectLocale(String? preferredLocale) {
    if (preferredLocale != null &&
        _locales.any((e) => e.localeId == preferredLocale)) {
      return preferredLocale;
    }
    if (_systemLocale.isNotEmpty &&
        _locales.any((e) => e.localeId == _systemLocale)) {
      return _systemLocale;
    }
    if (_locales.isNotEmpty) {
      return _locales.first.localeId;
    }
    return null;
  }

  @override
  Future<void> stop() async {
    _antiStuckTimer?.cancel();
    try {
      await _stt.stop();
      await _stt.cancel();
    } catch (_) {}
    _listening = false;
    _lastStatus = 'idle';
  }
}

class _VoskEngine implements _BaseEngine {
  static const _modelUrl =
      'https://alphacephei.com/vosk/models/vosk-model-small-ru-0.22.zip';
  static const _modelName = 'vosk-model-small-ru-0.22';

  final VoskFlutterPlugin _vosk = VoskFlutterPlugin.instance();
  final http.Client _client = http.Client();

  Model? _model;
  Recognizer? _recognizer;
  SpeechService? _speechService;

  StreamSubscription<String>? _partialSub;
  StreamSubscription<String>? _resultSub;

  bool _modelReady = false;
  bool _ready = false;
  bool _listening = false;
  String _lastError = '';
  String _lastStatus = 'idle';
  final String _selectedLocale = 'ru';
  final double _soundLevel = 0.0;
  double _downloadProgress = 0.0;
  String _modelPath = '';
  final int _sampleRate = 16000;

  @override
  String get name => 'Vosk';

  bool get modelReady => _modelReady;
  String get modelPath => _modelPath;
  double get downloadProgress => _downloadProgress;
  int get sampleRate => _sampleRate;

  @override
  bool get isReady => _ready;

  @override
  bool get isListening => _listening;

  @override
  String get lastError => _lastError;

  @override
  String get lastStatus => _lastStatus;

  @override
  String get selectedLocale => _selectedLocale;

  @override
  double get soundLevel => _soundLevel;

  @override
  Future<bool> init({
    bool force = false,
    String? preferredLocale,
    void Function(String status)? onStatus,
    void Function(String error)? onError,
    void Function(double progress)? onProgress,
  }) async {
    if (!Platform.isAndroid) {
      _ready = false;
      _lastError = 'Vosk not supported on this platform.';
      onError?.call(_lastError);
      return false;
    }
    if (_ready && !force) return true;

    _lastError = '';
    _lastStatus = 'init';
    onStatus?.call(_lastStatus);

    try {
      final modelPath = await _ensureModel(onProgress: onProgress);
      _modelPath = modelPath;
      _model = await _vosk.createModel(modelPath);
      _recognizer = await _vosk.createRecognizer(
        model: _model!,
        sampleRate: _sampleRate,
      );
      _speechService = await _vosk.initSpeechService(_recognizer!);
      _ready = true;
      _modelReady = true;
      _lastStatus = 'ready';
      onStatus?.call(_lastStatus);
      return true;
    } catch (e) {
      _ready = false;
      _modelReady = false;
      _lastError = 'Vosk init failed: $e';
      _lastStatus = 'error';
      onError?.call(_lastError);
      return false;
    }
  }

  Future<String> _ensureModel({void Function(double progress)? onProgress}) async {
    final docsDir = await getApplicationDocumentsDirectory();
    final modelsDir = Directory(path.join(docsDir.path, 'models'));
    if (!modelsDir.existsSync()) {
      await modelsDir.create(recursive: true);
    }

    final modelDir = Directory(path.join(modelsDir.path, _modelName));
    if (modelDir.existsSync()) {
      _downloadProgress = 1.0;
      onProgress?.call(_downloadProgress);
      return modelDir.path;
    }

    final zipPath = path.join(modelsDir.path, '$_modelName.zip');
    await _downloadModel(_modelUrl, zipPath, onProgress);
    await _extractZip(zipPath, modelsDir.path);
    try {
      await File(zipPath).delete();
    } catch (_) {}

    _downloadProgress = 1.0;
    onProgress?.call(_downloadProgress);
    return modelDir.path;
  }

  Future<void> _downloadModel(
    String url,
    String filePath,
    void Function(double progress)? onProgress,
  ) async {
    _downloadProgress = 0.0;
    onProgress?.call(_downloadProgress);

    final request = http.Request('GET', Uri.parse(url));
    final response = await _client.send(request);
    final total = response.contentLength ?? 0;

    final file = File(filePath);
    final sink = file.openWrite();
    int received = 0;
    await for (final chunk in response.stream) {
      received += chunk.length;
      sink.add(chunk);
      if (total > 0) {
        _downloadProgress = received / total;
        onProgress?.call(_downloadProgress);
      }
    }
    await sink.close();
  }

  Future<void> _extractZip(String zipPath, String outDir) async {
    final input = InputFileStream(zipPath);
    final archive = ZipDecoder().decodeStream(input);
    extractArchiveToDisk(archive, outDir);
    await input.close();
  }

  @override
  Future<bool> startListening({
    String? preferredLocale,
    required void Function(String) onPartial,
    required void Function(String) onFinal,
    required void Function(String) onStatus,
    required void Function(String) onError,
    required void Function(double) onSoundLevel,
  }) async {
    if (!_ready || _speechService == null) {
      onError('Vosk not ready.');
      return false;
    }

    _listening = true;
    _lastStatus = 'listening';
    onStatus(_lastStatus);

    _partialSub?.cancel();
    _resultSub?.cancel();

    _partialSub = _speechService!.onPartial().listen((event) {
      final text = _extractPartial(event);
      if (text.isNotEmpty) {
        onPartial(text);
      }
    });
    _resultSub = _speechService!.onResult().listen((event) {
      final text = _extractFinal(event);
      if (text.isNotEmpty) {
        onFinal(text);
      }
    });

    final started = await _speechService!.start(
      onRecognitionError: (e) {
        _lastError = e.toString();
        _lastStatus = 'error';
        _listening = false;
        onError('Vosk error: $_lastError');
      },
    );

    if (started != true) {
      _lastError = 'Vosk start failed';
      _lastStatus = 'error';
      _listening = false;
      onError(_lastError);
      return false;
    }

    return true;
  }

  String _extractPartial(String jsonStr) {
    try {
      final data = jsonDecode(jsonStr) as Map<String, dynamic>;
      return (data['partial'] ?? '').toString();
    } catch (_) {
      return '';
    }
  }

  String _extractFinal(String jsonStr) {
    try {
      final data = jsonDecode(jsonStr) as Map<String, dynamic>;
      return (data['text'] ?? '').toString();
    } catch (_) {
      return '';
    }
  }

  @override
  Future<void> stop() async {
    _partialSub?.cancel();
    _resultSub?.cancel();
    try {
      await _speechService?.stop();
      await _speechService?.cancel();
    } catch (_) {}
    _listening = false;
    _lastStatus = 'idle';
  }
}
