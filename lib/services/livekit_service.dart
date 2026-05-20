import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:livekit_client/livekit_client.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'orion_service.dart';

enum OrionActivationMode {
  alwaysOpen,
  wakeWord;

  String get wireName =>
      this == OrionActivationMode.wakeWord ? 'wake_word' : 'always_open';

  String get label =>
      this == OrionActivationMode.wakeWord ? 'Exigir Orion' : 'Sempre aberto';

  static OrionActivationMode fromWire(String? value) {
    return value == 'wake_word'
        ? OrionActivationMode.wakeWord
        : OrionActivationMode.alwaysOpen;
  }
}

enum OrionLiveKitState { disconnected, connecting, connected, error }

class LiveKitConnectionDetails {
  final String serverUrl;
  final String roomName;
  final String participantToken;

  const LiveKitConnectionDetails({
    required this.serverUrl,
    required this.roomName,
    required this.participantToken,
  });

  factory LiveKitConnectionDetails.fromJson(Map<String, dynamic> json) {
    return LiveKitConnectionDetails(
      serverUrl: json['serverUrl']?.toString() ?? '',
      roomName: json['roomName']?.toString() ?? '',
      participantToken: json['participantToken']?.toString() ?? '',
    );
  }
}

class LiveKitConnectionException implements Exception {
  final String message;

  const LiveKitConnectionException(this.message);

  @override
  String toString() => message;
}

class LiveKitService extends ChangeNotifier {
  Room? _room;
  EventsListener<RoomEvent>? _listener;

  OrionLiveKitState state = OrionLiveKitState.disconnected;
  String roomName = '';
  String error = '';
  bool microphoneMuted = false;
  OrionActivationMode activationMode = OrionActivationMode.alwaysOpen;

  /// Chamado quando o agente (Core) pede troca de modo via mensagem LiveKit.
  void Function(OrionActivationMode mode)? onRemoteModeChange;

  bool get isConnected => state == OrionLiveKitState.connected;
  bool get isConnecting => state == OrionLiveKitState.connecting;

  /// Nível de áudio atual (0..1) — o maior entre o seu microfone e o do Orion.
  /// Alimenta o visualizador de onda. Retorna 0 quando desconectado.
  double get activityLevel {
    final room = _room;
    if (room == null) return 0;
    var level = room.localParticipant?.audioLevel ?? 0.0;
    for (final p in room.remoteParticipants.values) {
      if (p.audioLevel > level) level = p.audioLevel;
    }
    return level.clamp(0.0, 1.0);
  }

  Future<void> loadActivationMode() async {
    final prefs = await SharedPreferences.getInstance();
    activationMode = OrionActivationMode.fromWire(
      prefs.getString('orion_activation_mode'),
    );
    notifyListeners();
  }

  Future<void> saveActivationMode(OrionActivationMode mode) async {
    activationMode = mode;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('orion_activation_mode', mode.wireName);
    notifyListeners();
  }

  Future<LiveKitConnectionDetails> _fetchConnectionDetails() async {
    final base = await OrionService.baseUrl();
    final headers = await OrionService.headers();
    final response = await http
        .post(
          Uri.parse('$base/livekit/connection-details'),
          headers: headers,
          body: jsonEncode({
            'client': 'orion_mobile',
            'activationMode': activationMode.wireName,
            'participantName': 'Rael Mobile',
            'participantIdentity':
                'orion_mobile_${DateTime.now().millisecondsSinceEpoch}',
            'room_config': {
              'agents': [
                {'agent_name': 'orion'},
              ],
            },
          }),
        )
        .timeout(const Duration(seconds: 12));

    if (response.statusCode < 200 || response.statusCode >= 300) {
      final body = utf8.decode(response.bodyBytes, allowMalformed: true);
      if (_looksLikeHtml(body)) {
        throw const LiveKitConnectionException(
          'A URL do LiveKit caiu no HUD, nao no Core. Use a URL do Core sem :3001 e confira o Tailscale Serve: /livekit precisa apontar para 3030.',
        );
      }
      throw LiveKitConnectionException(
        'LiveKit ${response.statusCode}: ${_shortErrorBody(body)}',
      );
    }
    try {
      return LiveKitConnectionDetails.fromJson(
        jsonDecode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>,
      );
    } catch (_) {
      throw const LiveKitConnectionException(
        'O Core respondeu em um formato inesperado para o LiveKit.',
      );
    }
  }

  bool _looksLikeHtml(String body) {
    final lower = body.trimLeft().toLowerCase();
    return lower.startsWith('<!doctype html') ||
        lower.startsWith('<html') ||
        lower.contains('/_next/static/');
  }

  String _shortErrorBody(String body) {
    final normalized = body.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (normalized.isEmpty) return 'sem detalhes';
    if (normalized.length <= 180) return normalized;
    return '${normalized.substring(0, 180)}...';
  }

  Future<void> connect() async {
    if (state == OrionLiveKitState.connecting ||
        state == OrionLiveKitState.connected) {
      return;
    }
    state = OrionLiveKitState.connecting;
    error = '';
    notifyListeners();

    try {
      final details = await _fetchConnectionDetails();
      final room = Room(
        roomOptions: const RoomOptions(
          adaptiveStream: true,
          dynacast: true,
          defaultAudioCaptureOptions: AudioCaptureOptions(
            echoCancellation: true,
            noiseSuppression: true,
            autoGainControl: true,
            voiceIsolation: true,
          ),
          defaultAudioOutputOptions: AudioOutputOptions(speakerOn: true),
        ),
      );

      _listener?.dispose();
      _listener = room.createListener()
        ..on<RoomReconnectingEvent>((_) {
          state = OrionLiveKitState.connecting;
          notifyListeners();
        })
        ..on<RoomReconnectedEvent>((_) {
          state = OrionLiveKitState.connected;
          notifyListeners();
        })
        ..on<RoomDisconnectedEvent>((_) {
          _room = null;
          roomName = '';
          microphoneMuted = false;
          state = OrionLiveKitState.disconnected;
          notifyListeners();
        })
        ..on<DataReceivedEvent>((event) => _handleData(event.data));

      await room.connect(details.serverUrl, details.participantToken);
      _room = room;
      roomName = details.roomName;
      await room.startAudio();
      await room.setSpeakerOn(true, forceSpeakerOutput: true);
      await room.localParticipant?.setMicrophoneEnabled(
        true,
        audioCaptureOptions: const AudioCaptureOptions(
          echoCancellation: true,
          noiseSuppression: true,
          autoGainControl: true,
          voiceIsolation: true,
        ),
      );
      microphoneMuted = false;
      state = OrionLiveKitState.connected;
      notifyListeners();
    } catch (caught) {
      await disconnect();
      error = caught.toString();
      state = OrionLiveKitState.error;
      notifyListeners();
    }
  }

  Future<void> disconnect() async {
    final room = _room;
    _room = null;
    _listener?.dispose();
    _listener = null;
    if (room != null) {
      await room.localParticipant
          ?.setMicrophoneEnabled(false)
          .catchError((_) => null);
      await room.disconnect();
      await room.dispose();
    }
    roomName = '';
    microphoneMuted = false;
    if (state != OrionLiveKitState.error) {
      state = OrionLiveKitState.disconnected;
    }
    notifyListeners();
  }

  /// Trata mensagens de dados vindas do agente (ex.: troca de modo de voz).
  void _handleData(List<int> data) {
    try {
      final decoded = jsonDecode(utf8.decode(data));
      if (decoded is Map && decoded['cmd'] == 'set_voice_mode') {
        final mode = OrionActivationMode.fromWire(decoded['mode']?.toString());
        onRemoteModeChange?.call(mode);
      }
    } catch (_) {}
  }

  Future<void> setMicrophoneMuted(bool muted) async {
    microphoneMuted = muted;
    notifyListeners();
    final room = _room;
    if (room == null) return;
    try {
      await room.localParticipant?.setMicrophoneEnabled(!muted);
    } catch (caught) {
      error = caught.toString();
      notifyListeners();
    }
  }

  Future<void> toggleMicrophoneMuted() => setMicrophoneMuted(!microphoneMuted);

  Future<void> reconnect() async {
    await disconnect();
    await connect();
  }

  @override
  void dispose() {
    _listener?.dispose();
    _room?.disconnect();
    _room?.dispose();
    super.dispose();
  }
}
