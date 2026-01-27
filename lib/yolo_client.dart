import 'dart:convert';
import 'dart:typed_data';
import 'package:http/http.dart' as http;

class YoloDetection {
  final String label;
  final double conf;
  final List<double> box; // [x1,y1,x2,y2] normalized or px
  YoloDetection({required this.label, required this.conf, required this.box});

  factory YoloDetection.fromJson(Map<String, dynamic> j) => YoloDetection(
    label: j['label'],
    conf: (j['conf'] as num).toDouble(),
    box: (j['box'] as List).map((e) => (e as num).toDouble()).toList(),
  );
}

class YoloClient {
  final String baseUrl; // например: http://192.168.1.10:8000
  YoloClient(this.baseUrl);

  Future<List<YoloDetection>> detectJpeg(Uint8List jpegBytes) async {
    final uri = Uri.parse('$baseUrl/detect');
    final req = http.MultipartRequest('POST', uri)
      ..files.add(
        http.MultipartFile.fromBytes('image', jpegBytes, filename: 'frame.jpg'),
      );

    final streamed = await req.send();
    final res = await http.Response.fromStream(streamed);

    if (res.statusCode != 200) {
      throw Exception('YOLO server ${res.statusCode}: ${res.body}');
    }

    final data = jsonDecode(res.body) as Map<String, dynamic>;
    final dets = (data['detections'] as List)
        .map((e) => YoloDetection.fromJson(e as Map<String, dynamic>))
        .toList();
    return dets;
  }
}
