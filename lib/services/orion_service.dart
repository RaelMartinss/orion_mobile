import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

class OrionService {
  static const defaultBaseUrl = 'https://desktop-2cphhq7.tailc7ff8a.ts.net';

  static Future<String> baseUrl() async {
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getString('orion_base_url');
    final raw = saved ?? defaultBaseUrl;
    return normalizeBaseUrl(raw);
  }

  static String normalizeBaseUrl(String value) {
    var cleaned = value.trim();
    if (cleaned.isEmpty) return defaultBaseUrl;
    cleaned = cleaned.replaceFirst(RegExp(r'^/+'), '');
    if (!RegExp(r'^https?://', caseSensitive: false).hasMatch(cleaned)) {
      cleaned = 'https://$cleaned';
    }
    cleaned = cleaned.replaceFirst(RegExp(r'/+$'), '');
    final uri = Uri.tryParse(cleaned);
    if (uri != null && uri.hasPort && uri.port == 3001) {
      return uri.replace(port: 443).toString().replaceFirst(':443', '');
    }
    return cleaned;
  }

  static bool looksLikeHudUrl(String value) {
    var cleaned = value.trim().replaceFirst(RegExp(r'^/+'), '');
    if (!RegExp(r'^https?://', caseSensitive: false).hasMatch(cleaned)) {
      cleaned = 'https://$cleaned';
    }
    final uri = Uri.tryParse(cleaned);
    return uri?.port == 3001;
  }

  static Future<String> _token() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString('orion_token') ?? '';
  }

  static Future<Map<String, String>> headers() async {
    final token = await _token();
    return {
      'Content-Type': 'application/json',
      if (token.isNotEmpty) 'X-Orion-Token': token,
    };
  }

  /// Verifica se o PC está online. Retorna true/false.
  static Future<bool> isOnline() async {
    try {
      final base = await baseUrl();
      final res = await http
          .get(Uri.parse('$base/health'))
          .timeout(const Duration(seconds: 5));
      return res.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  /// Envia um comando de texto e retorna a resposta do Orion.
  static Future<String> enviarComando(String texto) async {
    final base = await baseUrl();
    final headers = await OrionService.headers();
    final res = await http
        .post(
          Uri.parse('$base/ask'),
          headers: headers,
          body: jsonEncode({
            'text': texto,
            'source': 'voice',
            'responseStyle': 'voice',
            'maxChars': 260,
          }),
        )
        .timeout(const Duration(seconds: 90));

    if (res.statusCode == 200) {
      final data = jsonDecode(utf8.decode(res.bodyBytes));
      final result = data['result'];
      if (result is Map) {
        final message = result['message']?.toString().trim();
        if (message != null && message.isNotEmpty) return message;

        final toolResult = result['toolResult'];
        if (toolResult is Map) {
          final output = toolResult['output'];
          if (output is Map) {
            final outputMessage = output['message']?.toString().trim();
            if (outputMessage != null && outputMessage.isNotEmpty) {
              return outputMessage;
            }
          }
          final error = toolResult['error']?.toString().trim();
          if (error != null && error.isNotEmpty) return error;
        }
      }
      final message = data['message']?.toString().trim();
      return message == null || message.isEmpty ? 'Sem resposta.' : message;
    }
    throw Exception('Erro ${res.statusCode}');
  }

  /// Salva configurações de conexão.
  static Future<void> salvarConfig({
    required String baseUrl,
    String token = '',
  }) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('orion_base_url', normalizeBaseUrl(baseUrl));
    await prefs.setString('orion_token', token);
  }
}
