import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:speech_to_text/speech_to_text.dart';
import '../services/orion_service.dart';
import '../services/android_actions.dart';
import '../services/livekit_service.dart';
import '../update_ui.dart';
import 'settings_screen.dart';

enum OrionState { idle, listening, processing, responding, offline }

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen>
    with SingleTickerProviderStateMixin {
  final SpeechToText _stt = SpeechToText();
  final FlutterTts _tts = FlutterTts();
  final LiveKitService _liveKit = LiveKitService();

  OrionState _state = OrionState.idle;
  String _statusText = 'Toque para falar';
  String _resposta = '';
  bool _sttDisponivel = false;

  late AnimationController _pulseController;
  late Animation<double> _pulseAnim;

  static const _channel = MethodChannel(
    'br.com.orion.mobile/accessibility',
  );

  @override
  void initState() {
    super.initState();
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1000),
    )..repeat(reverse: true);
    _pulseAnim = Tween<double>(begin: 1.0, end: 1.15).animate(
      CurvedAnimation(parent: _pulseController, curve: Curves.easeInOut),
    );
    _liveKit.addListener(_onLiveKitChanged);
    _liveKit.onRemoteModeChange = _onTrocaModoRemota;
    _init();
  }

  void _onLiveKitChanged() {
    if (mounted) setState(() {});
  }

  /// O agente (Core) pediu para trocar o modo de voz — salva e reconecta com a
  /// flag nova. Espera um instante para o Orion terminar a confirmação falada.
  Future<void> _onTrocaModoRemota(OrionActivationMode mode) async {
    if (mode == _liveKit.activationMode) return;
    await _liveKit.saveActivationMode(mode);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Modo de voz: ${mode.label}')),
    );
    await Future.delayed(const Duration(milliseconds: 1800));
    if (!mounted) return;
    await _aplicarModoAtivacao();
  }

  Future<void> _init() async {
    await SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
    await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    try {
      await _channel.invokeMethod('setKeepScreenOn', {'enabled': true});
    } catch (_) {}
    await _initTts();
    await _initStt();
    await _liveKit.loadActivationMode();
    await _aplicarModoAtivacao();
    // Verifica se há versão nova no GitHub (falha em silêncio se offline)
    if (mounted) await checkAndPromptUpdate(context);
  }

  /// Os dois modos usam LiveKit. O modo escolhido vai como flag pro Core ao
  /// conectar; em "Exigir Orion" o próprio agente fica em silêncio até ouvir
  /// "Orion". Por isso aqui só garantimos a conexão (reconecta se já estava
  /// conectado, para reaplicar o modo).
  Future<void> _aplicarModoAtivacao() async {
    final online = await _verificarConexao();
    if (!online) return;
    if (_liveKit.isConnected || _liveKit.isConnecting) {
      await _liveKit.reconnect();
    } else {
      await _liveKit.connect();
    }
  }

  Future<void> _initTts() async {
    await _tts.setLanguage('pt-BR');
    await _tts.setSpeechRate(0.5);
    await _tts.setVolume(1.0);
    _tts.setCompletionHandler(() {
      if (mounted) setState(() => _state = OrionState.idle);
    });
  }

  Future<void> _initStt() async {
    final status = await Permission.microphone.request();
    if (status.isGranted) {
      _sttDisponivel = await _stt.initialize(onError: _handleSpeechError);
    }
  }

  void _handleSpeechError(dynamic error) {
    final msg = error.errorMsg?.toString() ?? error.toString();
    if (msg == 'error_no_match' || msg == 'error_speech_timeout') {
      _resetAfterNoSpeech();
      return;
    }
    if (mounted) {
      setState(() {
        _state = OrionState.idle;
        _statusText = 'Não consegui ouvir. Tente de novo.';
      });
    }
  }

  void _resetAfterNoSpeech() {
    if (!mounted) return;
    setState(() {
      _state = OrionState.idle;
      _statusText = 'Não ouvi nada. Toque para falar.';
      _resposta = '';
    });
  }

  Future<bool> _verificarConexao() async {
    final online = await OrionService.isOnline();
    if (mounted) {
      setState(() {
        _state = online ? OrionState.idle : OrionState.offline;
        _statusText = online ? _liveKitStatusText : 'PC offline';
      });
    }
    return online;
  }

  void _setStatus(String msg) {
    if (mounted) setState(() => _statusText = msg);
  }

  Future<void> _toggleEscuta() async {
    if (_state == OrionState.offline) {
      await _verificarConexao();
      return;
    }
    if (_state == OrionState.listening) {
      await _pararEscuta();
      return;
    }
    if (_state == OrionState.responding) {
      await _tts.stop();
      setState(() {
        _state = OrionState.idle;
        _statusText = 'Toque para falar';
      });
      return;
    }
    if (_state != OrionState.idle) return;
    await _iniciarEscuta();
  }

  Future<void> _toggleLiveKit() async {
    await _liveKit.loadActivationMode();
    if (_liveKit.isConnected || _liveKit.isConnecting) {
      await _liveKit.disconnect();
      return;
    }
    final online = await _verificarConexao();
    if (online) await _liveKit.connect();
  }

  String get _liveKitStatusText {
    switch (_liveKit.state) {
      case OrionLiveKitState.connected:
        return _liveKit.microphoneMuted
            ? 'LiveKit conectado · microfone mutado'
            : 'LiveKit ouvindo · ${_liveKit.activationMode.label}';
      case OrionLiveKitState.connecting:
        return 'Conectando LiveKit...';
      case OrionLiveKitState.error:
        return 'LiveKit com erro';
      case OrionLiveKitState.disconnected:
        return 'LiveKit desconectado';
    }
  }

  Future<void> _iniciarEscuta() async {
    if (!_sttDisponivel) {
      _setStatus('Microfone indisponível');
      return;
    }

    setState(() {
      _state = OrionState.listening;
      _statusText = 'Ouvindo...';
      _resposta = '';
    });

    await _stt.listen(
      localeId: 'pt_BR',
      listenFor: const Duration(seconds: 15),
      pauseFor: const Duration(seconds: 3),
      onResult: (result) {
        if (result.finalResult) {
          _processarTexto(result.recognizedWords);
        }
      },
    );
  }

  Future<void> _pararEscuta() async {
    await _stt.stop();
    final texto = _stt.lastRecognizedWords;
    if (texto.isNotEmpty) {
      _processarTexto(texto);
    } else {
      setState(() {
        _state = OrionState.idle;
        _statusText = 'Toque para falar';
      });
    }
  }

  Future<void> _processarTexto(String texto) async {
    if (texto.trim().isEmpty) {
      setState(() {
        _state = OrionState.idle;
        _statusText = 'Toque para falar';
      });
      return;
    }

    setState(() {
      _state = OrionState.processing;
      _statusText = 'Processando...';
      _resposta = '"$texto"';
    });

    try {
      // Tenta ação local primeiro
      final acao = await AndroidActions.tentar(texto);
      if (acao.handled) {
        if (mounted && acao.feedback.isNotEmpty) {
          setState(() {
            _state = OrionState.responding;
            _statusText = 'Orion';
            _resposta = acao.feedback;
          });
          await _tts.speak(acao.feedback);
        } else if (mounted) {
          setState(() {
            _state = OrionState.idle;
            _statusText = 'Toque para falar';
          });
        }
        return;
      }

      // Ação não reconhecida localmente — envia pro PC
      final resposta = await OrionService.enviarComando(texto);
      if (mounted) {
        setState(() {
          _state = OrionState.responding;
          _statusText = 'Orion';
          _resposta = resposta;
        });
        await _tts.speak(resposta);
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _state = OrionState.offline;
          _statusText = 'Erro de conexão';
          _resposta = e.toString();
        });
      }
    }
  }

  Color get _buttonColor {
    switch (_state) {
      case OrionState.listening:
        return const Color(0xFFFF3B30);
      case OrionState.processing:
        return const Color(0xFFFF9500);
      case OrionState.responding:
        return const Color(0xFF34C759);
      case OrionState.offline:
        return const Color(0xFF636366);
      case OrionState.idle:
        return const Color(0xFF00D4FF);
    }
  }

  @override
  void dispose() {
    _pulseController.dispose();
    _liveKit.removeListener(_onLiveKitChanged);
    _liveKit.dispose();
    _stt.cancel();
    _tts.stop();
    _channel
        .invokeMethod('setKeepScreenOn', {'enabled': false})
        .catchError((_) {});
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isActive =
        _state == OrionState.listening ||
        _state == OrionState.processing ||
        _state == OrionState.responding;

    return Scaffold(
      backgroundColor: const Color(0xFF0A0A0A),
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        title: const Text(
          'ORION',
          style: TextStyle(
            color: Color(0xFF00D4FF),
            fontSize: 18,
            fontWeight: FontWeight.w300,
            letterSpacing: 8,
          ),
        ),
        centerTitle: true,
        actions: [
          IconButton(
            icon: const Icon(Icons.settings_outlined, color: Color(0xFF636366)),
            onPressed: () async {
              final modoAntes = _liveKit.activationMode;
              await Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const SettingsScreen()),
              );
              await _liveKit.loadActivationMode();
              if (!mounted) return;
              if (_liveKit.activationMode != modoAntes) {
                await _aplicarModoAtivacao(); // modo mudou → reconecta com o novo flag
              } else {
                await _verificarConexao();
              }
            },
          ),
        ],
      ),
      body: Column(
        children: [
          // Status
          Expanded(
            flex: 2,
            child: Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  // Indicador de estado
                  Container(
                    width: 8,
                    height: 8,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: _state == OrionState.offline
                          ? const Color(0xFF636366)
                          : const Color(0xFF00D4FF),
                      boxShadow: _state != OrionState.offline
                          ? [
                              BoxShadow(
                                color: const Color(
                                  0xFF00D4FF,
                                ).withValues(alpha: 0.6),
                                blurRadius: 8,
                                spreadRadius: 2,
                              ),
                            ]
                          : null,
                    ),
                  ),
                  const SizedBox(height: 16),
                  Text(
                    _liveKit.state == OrionLiveKitState.disconnected ||
                            _liveKit.state == OrionLiveKitState.error
                        ? _statusText
                        : _liveKitStatusText,
                    style: const TextStyle(
                      color: Color(0xFF8E8E93),
                      fontSize: 14,
                      letterSpacing: 1,
                    ),
                  ),
                ],
              ),
            ),
          ),

          // Resposta
          Expanded(
            flex: 3,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 32),
              child: Center(
                child: SingleChildScrollView(
                  child: Text(
                    _liveKit.state == OrionLiveKitState.error
                        ? _liveKit.error
                        : _resposta,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: _state == OrionState.processing
                          ? const Color(0xFF636366)
                          : Colors.white,
                      fontSize: _state == OrionState.processing ? 14 : 16,
                      height: 1.6,
                      fontStyle: _state == OrionState.processing
                          ? FontStyle.italic
                          : FontStyle.normal,
                    ),
                  ),
                ),
              ),
            ),
          ),

          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 28),
            child: Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: _toggleLiveKit,
                    style: OutlinedButton.styleFrom(
                      foregroundColor: const Color(0xFF00D4FF),
                      side: const BorderSide(color: Color(0xFF00D4FF)),
                      padding: const EdgeInsets.symmetric(vertical: 14),
                    ),
                    child: Text(
                      _liveKit.isConnected
                          ? 'Sair LiveKit'
                          : _liveKit.isConnecting
                          ? 'Conectando...'
                          : 'Conectar LiveKit',
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: OutlinedButton(
                    onPressed: _liveKit.isConnected
                        ? () => _liveKit.toggleMicrophoneMuted()
                        : _toggleEscuta,
                    style: OutlinedButton.styleFrom(
                      foregroundColor: Colors.white,
                      side: const BorderSide(color: Color(0xFF2C2C2E)),
                      padding: const EdgeInsets.symmetric(vertical: 14),
                    ),
                    child: Text(
                      _liveKit.isConnected
                          ? (_liveKit.microphoneMuted ? 'Desmutar' : 'Mutar')
                          : 'Falar manual',
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 22),

          // Botão principal
          Padding(
            padding: const EdgeInsets.only(bottom: 64),
            child: GestureDetector(
              onTap: _liveKit.isConnected
                  ? () => _liveKit.toggleMicrophoneMuted()
                  : _toggleLiveKit,
              child: AnimatedBuilder(
                animation: _pulseAnim,
                builder: (_, child) => Transform.scale(
                  scale: isActive ? _pulseAnim.value : 1.0,
                  child: child,
                ),
                child: Container(
                  width: 88,
                  height: 88,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: _liveKit.isConnected
                        ? (_liveKit.microphoneMuted
                              ? const Color(0xFF636366)
                              : const Color(0xFF00D4FF))
                        : _buttonColor,
                    boxShadow: [
                      BoxShadow(
                        color:
                            (_liveKit.isConnected
                                    ? const Color(0xFF00D4FF)
                                    : _buttonColor)
                                .withValues(alpha: 0.4),
                        blurRadius: 24,
                        spreadRadius: 4,
                      ),
                    ],
                  ),
                  child:
                      _liveKit.isConnecting || _state == OrionState.processing
                      ? const Padding(
                          padding: EdgeInsets.all(24),
                          child: CircularProgressIndicator(
                            color: Colors.white,
                            strokeWidth: 2,
                          ),
                        )
                      : Icon(
                          _liveKit.isConnected
                              ? (_liveKit.microphoneMuted
                                    ? Icons.mic_off_rounded
                                    : Icons.mic_rounded)
                              : Icons.sensors_rounded,
                          color: Colors.white,
                          size: 36,
                        ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
