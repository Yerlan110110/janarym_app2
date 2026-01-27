import 'dart:typed_data';

import 'package:camera/camera.dart';
import 'package:image/image.dart' as img;

class FrameProvider {
  CameraController? _controller;
  bool _streaming = false;
  bool _processing = false;
  DateTime _lastFrameAt = DateTime.fromMillisecondsSinceEpoch(0);

  Uint8List? latestJpeg;

  CameraController? get controller => _controller;
  bool get isStreaming => _streaming;

  Future<void> init() async {
    if (_controller != null) return;

    final cameras = await availableCameras();
    if (cameras.isEmpty) {
      throw Exception('Камера не найдена');
    }

    final camera = cameras.firstWhere(
      (c) => c.lensDirection == CameraLensDirection.back,
      orElse: () => cameras.first,
    );

    final controller = CameraController(
      camera,
      ResolutionPreset.medium,
      enableAudio: false,
      imageFormatGroup: ImageFormatGroup.yuv420,
    );

    await controller.initialize();
    _controller = controller;
  }

  Future<void> start() async {
    final controller = _controller;
    if (controller == null) {
      await init();
    }
    if (_streaming) return;

    _streaming = true;
    await _controller!.startImageStream(_onImage);
  }

  Future<void> stop() async {
    if (!_streaming) return;
    _streaming = false;
    await _controller?.stopImageStream();
  }

  Future<void> dispose() async {
    await stop();
    await _controller?.dispose();
    _controller = null;
  }

  void _onImage(CameraImage image) {
    if (!_streaming) return;
    if (_processing) return;

    final now = DateTime.now();
    if (now.difference(_lastFrameAt) < const Duration(milliseconds: 500)) {
      return;
    }

    _processing = true;
    _lastFrameAt = now;

    try {
      final jpeg = _convertYuv420ToJpeg(image, quality: 75);
      latestJpeg = jpeg;
    } finally {
      _processing = false;
    }
  }

  Uint8List _convertYuv420ToJpeg(CameraImage image, {int quality = 75}) {
    final converted = _convertYuv420ToImage(image);
    final jpg = img.encodeJpg(converted, quality: quality);
    return Uint8List.fromList(jpg);
  }

  img.Image _convertYuv420ToImage(CameraImage image) {
    final width = image.width;
    final height = image.height;

    final yPlane = image.planes[0];
    final uPlane = image.planes[1];
    final vPlane = image.planes[2];

    final yBytes = yPlane.bytes;
    final uBytes = uPlane.bytes;
    final vBytes = vPlane.bytes;

    final yRowStride = yPlane.bytesPerRow;
    final uvRowStride = uPlane.bytesPerRow;
    final uvPixelStride = uPlane.bytesPerPixel ?? 1;

    final imageBuffer = img.Image(width: width, height: height);

    for (int y = 0; y < height; y++) {
      final yRowOffset = yRowStride * y;
      final uvRowOffset = uvRowStride * (y >> 1);

      for (int x = 0; x < width; x++) {
        final yIndex = yRowOffset + x;
        final uvIndex = uvRowOffset + (x >> 1) * uvPixelStride;

        final yp = yBytes[yIndex];
        final up = uBytes[uvIndex];
        final vp = vBytes[uvIndex];

        final yVal = yp.toDouble();
        final uVal = up.toDouble() - 128.0;
        final vVal = vp.toDouble() - 128.0;

        int r = (yVal + 1.402 * vVal).round();
        int g = (yVal - 0.344136 * uVal - 0.714136 * vVal).round();
        int b = (yVal + 1.772 * uVal).round();

        if (r < 0) r = 0;
        if (r > 255) r = 255;
        if (g < 0) g = 0;
        if (g > 255) g = 255;
        if (b < 0) b = 0;
        if (b > 255) b = 255;

        imageBuffer.setPixelRgba(x, y, r, g, b, 255);
      }
    }

    return imageBuffer;
  }
}
