import 'dart:async';
import 'dart:convert';
import 'package:android_intent_plus/android_intent.dart';
import 'package:android_intent_plus/flag.dart';
import 'package:camera/camera.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:permission_handler/permission_handler.dart';
import 'package:url_launcher/url_launcher.dart';
import 'orion_service.dart';

class _Phone {
  static const _ch = MethodChannel('br.com.orion.mobile/accessibility');

  static Future<List<Map<String, String>>> buscarContatos(String nome) async {
    try {
      final List raw = await _ch.invokeMethod('getContacts', {'name': nome});
      return raw.map((e) => Map<String, String>.from(e as Map)).toList();
    } catch (_) {
      return [];
    }
  }

  static Future<bool> ligar(String numero) async {
    try {
      return await _ch.invokeMethod('callNumber', {'number': numero}) ?? false;
    } catch (_) {
      return false;
    }
  }

  static Future<Map<String, int>> getBateria() async {
    try {
      final Map raw = await _ch.invokeMethod('getBattery');
      return {
        'level': raw['level'] as int,
        'charging': (raw['charging'] as bool) ? 1 : 0,
      };
    } catch (_) {
      return {'level': -1, 'charging': 0};
    }
  }

  static Future<Map<String, int>> setVolume({
    int? delta,
    int? absolute,
    bool mute = false,
  }) async {
    try {
      final args = <String, Object>{'mute': mute, 'stream': 'media'};
      if (delta != null) {
        args['delta'] = delta;
      }
      if (absolute != null) {
        args['absolute'] = absolute;
      }
      final Map raw = await _ch.invokeMethod('setVolume', {...args});
      return {'current': raw['current'] as int, 'max': raw['max'] as int};
    } catch (_) {
      return {'current': -1, 'max': -1};
    }
  }

  static Future<List<Map<String, String>>> getAgenda({int days = 7}) async {
    try {
      final List raw = await _ch.invokeMethod('getCalendarEvents', {
        'days': days,
      });
      return raw.map((e) => Map<String, String>.from(e as Map)).toList();
    } catch (_) {
      return [];
    }
  }
}

/// Resultado de uma ação local.
class ActionResult {
  final bool handled; // true = foi uma ação local, false = manda pro PC
  final String feedback; // texto para o TTS falar
  const ActionResult({required this.handled, this.feedback = ''});
}

/// Detecta e executa ações locais do Android.
/// Retorna ActionResult com handled=false se não reconheceu como ação local.
class AndroidActions {
  static CameraController? _camCtrl;

  // ── Palavras-chave que NUNCA devem ir pro PC ────────────────────────────────
  // Se o texto contiver qualquer uma dessas, é ação mobile mesmo que não reconheça.

  static const _exclusivoMobile = [
    'lanterna',
    'bluetooth',
    'modo avião',
    'wi-fi',
    'wifi',
    'timer',
    'cronômetro',
    'alarme',
    'bateria',
    'volume',
  ];

  // ── Router principal ────────────────────────────────────────────────────────

  static Future<ActionResult> tentar(String texto) async {
    final t = texto.toLowerCase().trim();

    // Agenda
    if (_match(t, [
      'agenda',
      'compromisso',
      'evento',
      'reunião',
      'o que tenho',
      'o que tem hoje',
      'minha agenda',
      'próximo evento',
    ])) {
      return _agenda(t);
    }

    // Ligação
    if (_match(t, [
      'liga para',
      'liga pro',
      'liga pra',
      'ligar para',
      'ligar pro',
      'chama o',
      'chama a',
      'disca para',
      'faz uma ligação',
    ])) {
      return _ligar(t);
    }

    // Bateria
    if (_match(t, [
      'bateria',
      'nível de carga',
      'quanto de carga',
      'carga do celular',
    ])) {
      return _bateria();
    }

    // Volume
    if (t.contains('volume') ||
        _match(t, [
          'aumenta o som',
          'diminui o som',
          'silencia',
          'mudo',
          'sem som',
        ])) {
      return _volume(t);
    }

    // Lanterna — captura qualquer menção a lanterna
    if (t.contains('lanterna')) {
      final desligar = _match(t, [
        'desliga',
        'apaga',
        'desative',
        'desativar',
        'desligar',
        'apagar',
        'off',
      ]);
      return _lanterna(!desligar);
    }

    // Alarme
    if (_match(t, ['alarme', 'acorda', 'me acorda', 'me desperta'])) {
      return _alarme(t);
    }

    // Timer
    if (t.contains('timer') ||
        t.contains('cronômetro') ||
        (t.contains('minuto') &&
            _match(t, ['por', 'durante', 'de', 'conta'])) ||
        (t.contains('segundo') &&
            _match(t, ['por', 'durante', 'de', 'conta']))) {
      return _timer(t);
    }

    // WhatsApp
    if (_match(t, ['whatsapp', 'zap', 'manda mensagem', 'manda zap'])) {
      return _whatsapp(t);
    }

    // Maps / Navegação
    if (_match(t, [
      'navega',
      'navegar',
      'como chegar',
      'rota para',
      'ir para',
      'me leva',
    ])) {
      return _maps(t);
    }

    // Abrir app
    if (_match(t, [
      'abre',
      'abrir',
      'abre o',
      'abrir o',
      'lança',
      'lançar',
      'abra',
    ])) {
      return _abrirApp(t);
    }

    // Bluetooth
    if (t.contains('bluetooth')) {
      return _bluetooth(t);
    }

    // Wi-Fi
    if (_match(t, ['wi-fi', 'wifi', 'wi fi'])) {
      return _wifi(t);
    }

    // Modo avião
    if (_match(t, ['modo avião', 'avião', 'airplane'])) {
      return _modoAviao(t);
    }

    // Guarda-chuva: palavra-chave mobile presente mas sem ação reconhecida
    // → bloqueia pro PC e responde localmente para não causar efeitos colaterais
    if (_exclusivoMobile.any((k) => t.contains(k))) {
      return const ActionResult(
        handled: true,
        feedback: 'Não entendi o comando. Pode repetir?',
      );
    }

    return const ActionResult(handled: false);
  }

  // ── Helpers ─────────────────────────────────────────────────────────────────

  static bool _match(String texto, List<String> palavras) {
    return palavras.any((p) => texto.contains(p));
  }

  static int? _extrairNumero(String texto) {
    final m = RegExp(r'\d+').firstMatch(texto);
    return m != null ? int.tryParse(m.group(0)!) : null;
  }

  // ── Lanterna ────────────────────────────────────────────────────────────────

  static Future<ActionResult> _lanterna(bool ligar) async {
    try {
      final cameras = await availableCameras();
      final traseira = cameras.firstWhere(
        (c) => c.lensDirection == CameraLensDirection.back,
        orElse: () => cameras.first,
      );

      if (ligar) {
        _camCtrl?.dispose();
        _camCtrl = CameraController(traseira, ResolutionPreset.low);
        await _camCtrl!.initialize();
        await _camCtrl!.setFlashMode(FlashMode.torch);
        return const ActionResult(handled: true, feedback: 'Lanterna ligada.');
      } else {
        await _camCtrl?.setFlashMode(FlashMode.off);
        await _camCtrl?.dispose();
        _camCtrl = null;
        return const ActionResult(
          handled: true,
          feedback: 'Lanterna desligada.',
        );
      }
    } catch (e) {
      return ActionResult(
        handled: true,
        feedback: 'Não consegui controlar a lanterna: $e',
      );
    }
  }

  // ── Alarme ──────────────────────────────────────────────────────────────────

  static Future<ActionResult> _alarme(String texto) async {
    // Extrai horário: "7h", "7:30", "às 7", "7 horas", "7 da manhã"
    final hora = RegExp(r'(\d{1,2})(?:\s*[h:]\s*(\d{2}))?').firstMatch(texto);

    if (hora == null) {
      // Sem horário → abre o app sem SKIP_UI para o usuário definir
      const intent = AndroidIntent(
        action: 'android.intent.action.SET_ALARM',
        arguments: {'android.intent.extra.alarm.SKIP_UI': false},
      );
      await intent.launch();
      return const ActionResult(
        handled: true,
        feedback: 'Para que horas quer o alarme?',
      );
    }

    final h = int.parse(hora.group(1)!);
    final min = hora.group(2) != null ? int.parse(hora.group(2)!) : 0;

    final intent = AndroidIntent(
      action: 'android.intent.action.SET_ALARM',
      arguments: {
        'android.intent.extra.alarm.HOUR': h,
        'android.intent.extra.alarm.MINUTES': min,
        'android.intent.extra.alarm.SKIP_UI': true, // cria sem abrir UI
        'android.intent.extra.alarm.MESSAGE': 'Orion',
        'android.intent.extra.alarm.VIBRATE': true,
      },
    );
    await intent.launch();
    final minStr = min.toString().padLeft(2, '0');
    return ActionResult(
      handled: true,
      feedback: 'Alarme criado para ${h}h$minStr.',
    );
  }

  // ── Timer ───────────────────────────────────────────────────────────────────

  static Future<ActionResult> _timer(String texto) async {
    final num = _extrairNumero(texto);
    final emSegundos = texto.contains('segundo');
    final segundos = num != null ? (emSegundos ? num : num * 60) : 60;

    final intent = AndroidIntent(
      action: 'android.intent.action.SET_TIMER',
      arguments: {
        'android.intent.extra.alarm.LENGTH': segundos,
        'android.intent.extra.alarm.SKIP_UI': true,
      },
    );
    await intent.launch();
    final label = emSegundos
        ? '$num segundo${num == 1 ? '' : 's'}'
        : '$num minuto${num == 1 ? '' : 's'}';
    return ActionResult(handled: true, feedback: 'Timer de $label iniciado.');
  }

  // ── WhatsApp ────────────────────────────────────────────────────────────────

  static Future<ActionResult> _whatsapp(String texto) async {
    String msg = '';
    final mMsg = RegExp(
      r'(?:que|dizendo|falando|escrevendo)\s+(.+)$',
    ).firstMatch(texto);
    if (mMsg != null) msg = mMsg.group(1)!.trim();

    // Tenta abrir via URL scheme whatsapp:// (mais confiável no MIUI)
    final schemeUri = Uri.parse(
      'whatsapp://send?text=${Uri.encodeComponent(msg)}',
    );
    if (await canLaunchUrl(schemeUri)) {
      await launchUrl(schemeUri, mode: LaunchMode.externalApplication);
      return const ActionResult(handled: true, feedback: 'Abrindo WhatsApp.');
    }

    // Fallback: URL scheme whatsapp://
    final uri = Uri.parse('whatsapp://send?text=${Uri.encodeComponent(msg)}');
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
      return const ActionResult(handled: true, feedback: 'Abrindo WhatsApp.');
    }

    // Fallback final: wa.me
    final waUri = Uri.parse('https://wa.me/');
    if (await canLaunchUrl(waUri)) {
      await launchUrl(waUri, mode: LaunchMode.externalApplication);
      return const ActionResult(handled: true, feedback: 'Abrindo WhatsApp.');
    }

    return const ActionResult(
      handled: true,
      feedback: 'WhatsApp não encontrado no celular.',
    );
  }

  // ── Maps ────────────────────────────────────────────────────────────────────

  static Future<ActionResult> _maps(String texto) async {
    // Extrai destino: "navega para X", "como chegar em X", "ir para X"
    String destino = '';
    final patterns = [
      RegExp(
        r'(?:navega para|rota para|ir para|me leva a|me leva para|como chegar em|como chegar a)\s+(.+)$',
      ),
    ];
    for (final p in patterns) {
      final m = p.firstMatch(texto);
      if (m != null) {
        destino = m.group(1)!.trim();
        break;
      }
    }
    if (destino.isEmpty) {
      return const ActionResult(
        handled: true,
        feedback: 'Para onde você quer ir?',
      );
    }

    final uri = Uri.parse(
      'google.navigation:q=${Uri.encodeComponent(destino)}&mode=d',
    );
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } else {
      // Fallback: abre Google Maps normal
      final fallback = Uri.parse(
        'https://maps.google.com/?q=${Uri.encodeComponent(destino)}',
      );
      await launchUrl(fallback, mode: LaunchMode.externalApplication);
    }
    return ActionResult(handled: true, feedback: 'Navegando para $destino.');
  }

  // ── Abrir App ────────────────────────────────────────────────────────────────

  // Mapa: nome → URL scheme (mais confiável que Intent no MIUI)
  static const _appSchemes = {
    'youtube': 'https://www.youtube.com',
    'spotify': 'spotify:',
    'instagram': 'instagram://app',
    'whatsapp': 'whatsapp://app',
    'telegram': 'tg:',
    'maps': 'https://maps.google.com',
    'gmail': 'googlegmail://',
    'netflix': 'nflx:',
    'tiktok': 'snssdk1233://',
  };

  // Mapa: nome → package (fallback quando scheme não funciona)
  static const _appPackages = {
    'youtube': 'com.google.android.youtube',
    'spotify': 'com.spotify.music',
    'instagram': 'com.instagram.android',
    'whatsapp': 'com.whatsapp',
    'telegram': 'org.telegram.messenger',
    'chrome': 'com.android.chrome',
    'câmera': 'com.miui.camera',
    'camera': 'com.miui.camera',
    'galeria': 'com.miui.gallery',
    'fotos': 'com.miui.gallery',
    'maps': 'com.google.android.apps.maps',
    'gmail': 'com.google.android.gm',
    'agenda': 'com.google.android.calendar',
    'calendar': 'com.google.android.calendar',
    'calculadora': 'com.miui.calculator',
    'netflix': 'com.netflix.mediaclient',
    'tiktok': 'com.zhiliaoapp.musically',
    'configurações': 'com.android.settings',
    'configuracoes': 'com.android.settings',
    'settings': 'com.android.settings',
    'arquivos': 'com.mi.android.globalFileexplorer',
    'files': 'com.mi.android.globalFileexplorer',
    'música': 'com.miui.player',
    'musica': 'com.miui.player',
  };

  static Future<ActionResult> _abrirApp(String texto) async {
    final m = RegExp(
      r'(?:abre|abrir|lança|lançar|abra)\s+(?:o\s+|a\s+)?(.+)$',
    ).firstMatch(texto);
    if (m == null) return const ActionResult(handled: false);

    final nomeApp = m.group(1)!.trim().toLowerCase();

    // Tenta URL scheme primeiro
    for (final entry in _appSchemes.entries) {
      if (nomeApp.contains(entry.key)) {
        final uri = Uri.parse(entry.value);
        if (await canLaunchUrl(uri)) {
          await launchUrl(uri, mode: LaunchMode.externalApplication);
          return ActionResult(handled: true, feedback: 'Abrindo $nomeApp.');
        }
        break;
      }
    }

    // Fallback: Intent com category LAUNCHER (correto para abrir apps)
    for (final entry in _appPackages.entries) {
      if (nomeApp.contains(entry.key)) {
        try {
          final intent = AndroidIntent(
            action: 'android.intent.action.MAIN',
            package: entry.value,
            componentName: '${entry.value}.MainActivity',
            flags: <int>[Flag.FLAG_ACTIVITY_NEW_TASK],
          );
          await intent.launch();
          return ActionResult(handled: true, feedback: 'Abrindo $nomeApp.');
        } catch (_) {
          // tenta sem componentName
          try {
            final intent = AndroidIntent(
              action: 'android.intent.action.MAIN',
              package: entry.value,
              flags: <int>[Flag.FLAG_ACTIVITY_NEW_TASK],
            );
            await intent.launch();
            return ActionResult(handled: true, feedback: 'Abrindo $nomeApp.');
          } catch (_) {}
        }
        break;
      }
    }

    // Fallback final: Play Store
    final storeUri = Uri.parse('market://search?q=$nomeApp');
    if (await canLaunchUrl(storeUri)) {
      await launchUrl(storeUri, mode: LaunchMode.externalApplication);
      return ActionResult(
        handled: true,
        feedback: 'App não encontrado. Abrindo Play Store.',
      );
    }
    return const ActionResult(handled: false);
  }

  // ── Bluetooth ────────────────────────────────────────────────────────────────
  // O Android moderno não permite que apps alternem Bluetooth direto, então
  // abrimos as configurações para o usuário ligar/desligar.

  static Future<ActionResult> _bluetooth(String texto) async {
    const intent = AndroidIntent(
      action: 'android.settings.BLUETOOTH_SETTINGS',
      flags: <int>[Flag.FLAG_ACTIVITY_NEW_TASK],
    );
    await intent.launch();
    return const ActionResult(
      handled: true,
      feedback: 'Abrindo as configurações de Bluetooth.',
    );
  }

  // ── Wi-Fi ────────────────────────────────────────────────────────────────────

  static Future<ActionResult> _wifi(String texto) async {
    // Painel deslizante de Wi-Fi (Android 10+), com fallback para a tela cheia.
    try {
      const panel = AndroidIntent(
        action: 'android.settings.panel.action.WIFI',
      );
      await panel.launch();
    } catch (_) {
      const intent = AndroidIntent(
        action: 'android.settings.WIFI_SETTINGS',
        flags: <int>[Flag.FLAG_ACTIVITY_NEW_TASK],
      );
      await intent.launch();
    }
    return const ActionResult(
      handled: true,
      feedback: 'Abrindo as configurações de Wi-Fi.',
    );
  }

  // ── Modo Avião ───────────────────────────────────────────────────────────────

  static Future<ActionResult> _modoAviao(String texto) async {
    const intent = AndroidIntent(
      action: 'android.settings.AIRPLANE_MODE_SETTINGS',
      flags: <int>[Flag.FLAG_ACTIVITY_NEW_TASK],
    );
    await intent.launch();
    return const ActionResult(
      handled: true,
      feedback: 'Abrindo as configurações de modo avião.',
    );
  }

  // ── Agenda ───────────────────────────────────────────────────────────────────

  static Future<ActionResult> _agenda(String texto) async {
    final t = texto;

    // Define quantos dias olhar
    final proximoEvento = _match(t, [
      'próxima',
      'proximo',
      'próximo',
      'proxima',
    ]);
    int days = 1;
    if (_match(t, ['semana', 'próximos 7', 'essa semana'])) {
      days = 7;
    } else if (_match(t, ['amanhã', 'amanha'])) {
      days = 2;
    } else if (_match(t, ['mês', 'mes', 'próximo mês'])) {
      days = 30;
    } else if (proximoEvento) {
      days = 14;
    }

    final perm = await Permission.calendarFullAccess.request();
    if (!perm.isGranted) {
      return const ActionResult(
        handled: true,
        feedback: 'Preciso de permissão para acessar o calendário.',
      );
    }

    final eventos = await _Phone.getAgenda(days: days);

    // Sincroniza pro PC em background (não bloqueia a resposta)
    _sincronizarAgendaPC(eventos);

    if (eventos.isEmpty) {
      final periodo = days == 1
          ? 'hoje'
          : days == 2
          ? 'nos próximos 2 dias'
          : 'nos próximos $days dias';
      return ActionResult(handled: true, feedback: 'Nenhum evento $periodo.');
    }

    // "próximo evento/reunião" → retorna só o primeiro
    if (proximoEvento) {
      final ev = eventos.first;
      final hora = ev['time'] ?? '';
      final titulo = ev['title'] ?? 'Evento';
      final data = ev['date'] ?? '';
      final quando = hora.isNotEmpty ? '$data às $hora' : data;
      return ActionResult(
        handled: true,
        feedback: 'Próximo evento: $titulo, $quando.',
      );
    }

    // Filtra por período se perguntou só de hoje
    final hoje = _dataHoje();
    final eventosHoje = eventos.where((e) => e['date'] == hoje).toList();
    final lista = (days == 1 && eventosHoje.isNotEmpty) ? eventosHoje : eventos;

    // Monta resposta falada (máx 4 eventos para não ficar longo)
    final partes = <String>[];
    for (final ev in lista.take(4)) {
      final hora = ev['time'] ?? '';
      final titulo = ev['title'] ?? 'Evento';
      partes.add(hora.isNotEmpty ? '$hora: $titulo' : titulo);
    }
    final total = lista.length;
    final extra = total > 4 ? ' e mais ${total - 4} eventos' : '';
    final periodo = days == 1
        ? 'hoje'
        : days == 2
        ? 'amanhã'
        : 'nos próximos $days dias';
    final fala = 'Você tem $periodo: ${partes.join(', ')}$extra.';

    return ActionResult(handled: true, feedback: fala);
  }

  static String _dataHoje() {
    final now = DateTime.now();
    final d = now.day.toString().padLeft(2, '0');
    final m = now.month.toString().padLeft(2, '0');
    return '$d/$m/${now.year}';
  }

  static void _sincronizarAgendaPC(List<Map<String, String>> eventos) async {
    try {
      final base = await OrionService.baseUrl();
      final headers = await OrionService.headers();
      await http
          .post(
            Uri.parse('$base/api/agenda'),
            headers: headers,
            body: jsonEncode({'eventos': eventos}),
          )
          .timeout(const Duration(seconds: 10));
    } catch (_) {} // falha silenciosa
  }

  // ── Ligação ──────────────────────────────────────────────────────────────────

  static Future<ActionResult> _ligar(String texto) async {
    // Extrai o nome após as palavras-chave
    final m = RegExp(
      r'(?:liga(?:r)? (?:para|pro|pra)|chama(?:r)? (?:o|a)?|disca(?:r)? (?:para|pro|pra)?|faz uma ligação (?:para|pro|pra))\s+(.+)$',
    ).firstMatch(texto);
    if (m == null) return const ActionResult(handled: false);
    // Remove artigos no início: "o amor" → "amor", "a maria" → "maria"
    final nome = m
        .group(1)!
        .trim()
        .replaceFirst(RegExp(r'^(?:o|a|os|as)\s+'), '')
        .trim();

    // Verifica permissão de contatos
    final contactPerm = await Permission.contacts.request();
    if (!contactPerm.isGranted) {
      return const ActionResult(
        handled: true,
        feedback: 'Preciso de permissão para acessar os contatos.',
      );
    }

    final contatos = await _Phone.buscarContatos(nome);
    if (contatos.isEmpty) {
      return ActionResult(
        handled: true,
        feedback: 'Não encontrei nenhum contato com o nome $nome.',
      );
    }

    final contato = contatos.first;
    final numero = contato['number']!;
    final nomeContato = contato['name']!;

    // Verifica permissão de ligação
    final callPerm = await Permission.phone.request();
    if (!callPerm.isGranted) {
      // Fallback: abre o discador
      final uri = Uri.parse('tel:$numero');
      await launchUrl(uri, mode: LaunchMode.externalApplication);
      return ActionResult(
        handled: true,
        feedback: 'Abrindo discador para $nomeContato.',
      );
    }

    final ok = await _Phone.ligar(numero);
    if (ok) {
      return ActionResult(
        handled: true,
        feedback: 'Ligando para $nomeContato.',
      );
    }
    return ActionResult(
      handled: true,
      feedback: 'Não consegui ligar para $nomeContato.',
    );
  }

  // ── Bateria ──────────────────────────────────────────────────────────────────

  static Future<ActionResult> _bateria() async {
    final info = await _Phone.getBateria();
    final level = info['level'] ?? -1;
    if (level < 0) {
      return const ActionResult(
        handled: true,
        feedback: 'Não consegui ler o nível de bateria.',
      );
    }
    final carregando = info['charging'] == 1;
    final extra = carregando ? ', carregando' : '';
    return ActionResult(
      handled: true,
      feedback: 'Bateria em $level por cento$extra.',
    );
  }

  // ── Volume ───────────────────────────────────────────────────────────────────

  static Future<ActionResult> _volume(String texto) async {
    final t = texto;

    // Silenciar
    if (_match(t, ['silencia', 'mudo', 'sem som', 'desliga o som'])) {
      await _Phone.setVolume(mute: true);
      return const ActionResult(handled: true, feedback: 'Som silenciado.');
    }

    // Máximo
    if (_match(t, ['máximo', 'maximo', 'no máximo', 'alto'])) {
      await _Phone.setVolume(absolute: 15);
      return const ActionResult(handled: true, feedback: 'Volume no máximo.');
    }

    // Número específico
    final numM = RegExp(r'volume\s+(?:para\s+)?(\d+)').firstMatch(t);
    if (numM != null) {
      final val = int.parse(numM.group(1)!).clamp(0, 15);
      await _Phone.setVolume(absolute: val);
      return ActionResult(
        handled: true,
        feedback: 'Volume ajustado para $val.',
      );
    }

    // Aumentar
    if (_match(t, ['aumenta', 'sobe', 'mais alto', 'subir'])) {
      final info = await _Phone.setVolume(delta: 1);
      final cur = info['current'] ?? 0;
      final max = info['max'] ?? 15;
      return ActionResult(
        handled: true,
        feedback: 'Volume aumentado. Nível $cur de $max.',
      );
    }

    // Diminuir
    if (_match(t, ['diminui', 'abaixa', 'mais baixo', 'baixar'])) {
      final info = await _Phone.setVolume(delta: -1);
      final cur = info['current'] ?? 0;
      final max = info['max'] ?? 15;
      return ActionResult(
        handled: true,
        feedback: 'Volume diminuído. Nível $cur de $max.',
      );
    }

    // Consulta sem ação
    return const ActionResult(handled: false);
  }
}
