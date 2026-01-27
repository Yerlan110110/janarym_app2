import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

class OpenAiVisionClient {
  final String apiKey;
  final String model;
  final http.Client _http;

  OpenAiVisionClient({
    required this.apiKey,
    required this.model,
    http.Client? httpClient,
  }) : _http = httpClient ?? http.Client();

  Future<String> describeBase64Jpeg({
    required String base64Image,
    required String prompt,
    int maxOutputTokens = 450,
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
      "max_output_tokens": maxOutputTokens,
    };

    final res = await _http.post(
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
}
