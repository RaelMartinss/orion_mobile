import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Uma atualização publicada no GitHub Releases.
class AppUpdate {
  final String version; // ex: "1.0.1"
  final String downloadUrl; // browser_download_url (público) ou asset API url
  final String notes; // corpo do release
  final bool authenticated; // baixar com token (repo privado)

  const AppUpdate({
    required this.version,
    required this.downloadUrl,
    required this.notes,
    required this.authenticated,
  });
}

/// Verifica, baixa e instala novas versões do app a partir do GitHub Releases.
///
/// Não usa a Play Store. O Android exige, uma única vez, que o usuário conceda
/// ao Orion a permissão "Instalar apps desconhecidos"; e mostra o instalador
/// do sistema a cada atualização. O app apenas baixa o APK e dispara o
/// instalador — quem instala é o sistema.
class UpdateService {
  static const _channel = MethodChannel('br.com.orion.mobile/accessibility');

  /// Repositório padrão (owner/repo). Pode ser trocado nas Configurações.
  static const defaultRepo = 'RaelMartinss/orion_mobile';

  static Future<String> repo() async {
    final prefs = await SharedPreferences.getInstance();
    final saved = (prefs.getString('orion_update_repo') ?? '').trim();
    return saved.isEmpty ? defaultRepo : saved;
  }

  static Future<String> _token() async {
    final prefs = await SharedPreferences.getInstance();
    return (prefs.getString('orion_update_token') ?? '').trim();
  }

  static Future<void> salvarConfig({required String repo, String token = ''}) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('orion_update_repo', repo.trim());
    await prefs.setString('orion_update_token', token.trim());
  }

  /// Consulta o último release. Retorna a atualização se houver versão mais
  /// nova que a instalada, ou null (também em qualquer erro — falha silenciosa).
  static Future<AppUpdate?> checkForUpdate() async {
    try {
      final r = await repo();
      if (!r.contains('/')) return null;
      final token = await _token();

      final headers = <String, String>{
        'Accept': 'application/vnd.github+json',
        if (token.isNotEmpty) 'Authorization': 'Bearer $token',
      };
      final res = await http
          .get(
            Uri.parse('https://api.github.com/repos/$r/releases/latest'),
            headers: headers,
          )
          .timeout(const Duration(seconds: 12));
      if (res.statusCode != 200) return null;

      final data = jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
      final tag = (data['tag_name']?.toString() ?? '')
          .replaceFirst(RegExp(r'^v', caseSensitive: false), '')
          .trim();
      if (tag.isEmpty) return null;

      // Escolhe o asset .apk; prefere o arm64 se houver vários (split-per-abi).
      final assets = (data['assets'] as List?) ?? const [];
      Map<String, dynamic>? apk;
      for (final raw in assets) {
        final a = raw as Map<String, dynamic>;
        final name = (a['name']?.toString() ?? '').toLowerCase();
        if (!name.endsWith('.apk')) continue;
        apk ??= a;
        if (name.contains('arm64')) {
          apk = a;
          break;
        }
      }
      if (apk == null) return null;

      final info = await PackageInfo.fromPlatform();
      if (!_isNewer(tag, info.version)) return null;

      final url = token.isNotEmpty
          ? (apk['url']?.toString() ?? '')
          : (apk['browser_download_url']?.toString() ?? '');
      if (url.isEmpty) return null;

      return AppUpdate(
        version: tag,
        downloadUrl: url,
        notes: data['body']?.toString() ?? '',
        authenticated: token.isNotEmpty,
      );
    } catch (_) {
      return null;
    }
  }

  /// Compara versões semânticas (ignora o "+build"). true se [remote] > [current].
  static bool _isNewer(String remote, String current) {
    List<int> parse(String v) => v
        .split('+')
        .first
        .split('.')
        .map((p) => int.tryParse(RegExp(r'\d+').stringMatch(p) ?? '') ?? 0)
        .toList();
    final a = parse(remote);
    final b = parse(current);
    final n = a.length > b.length ? a.length : b.length;
    for (var i = 0; i < n; i++) {
      final x = i < a.length ? a[i] : 0;
      final y = i < b.length ? b[i] : 0;
      if (x != y) return x > y;
    }
    return false;
  }

  /// O app tem a permissão "Instalar apps desconhecidos"?
  static Future<bool> canInstall() async {
    try {
      return await _channel.invokeMethod('canInstallPackages') ?? false;
    } catch (_) {
      return true;
    }
  }

  /// Abre a tela do sistema para conceder a permissão de instalação.
  static Future<void> openInstallSettings() async {
    try {
      await _channel.invokeMethod('openInstallPermissionSettings');
    } catch (_) {}
  }

  /// Baixa o APK (reportando o progresso 0..1) e dispara o instalador.
  static Future<void> downloadAndInstall(
    AppUpdate update, {
    void Function(double progress)? onProgress,
  }) async {
    final token = await _token();
    final req = http.Request('GET', Uri.parse(update.downloadUrl));
    if (update.authenticated && token.isNotEmpty) {
      req.headers['Authorization'] = 'Bearer $token';
      req.headers['Accept'] = 'application/octet-stream';
    }

    final client = http.Client();
    try {
      final resp = await client.send(req);
      if (resp.statusCode < 200 || resp.statusCode >= 300) {
        throw Exception('Falha no download (HTTP ${resp.statusCode})');
      }
      final total = resp.contentLength ?? 0;
      final dir = await getTemporaryDirectory();
      final file = File('${dir.path}/orion-update.apk');
      final sink = file.openWrite();
      var received = 0;
      await for (final chunk in resp.stream) {
        sink.add(chunk);
        received += chunk.length;
        if (total > 0) onProgress?.call(received / total);
      }
      await sink.flush();
      await sink.close();

      await _channel.invokeMethod('installApk', {'path': file.path});
    } finally {
      client.close();
    }
  }
}
