import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../services/livekit_service.dart';
import '../services/orion_service.dart';
import '../services/update_service.dart';
import '../update_ui.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final _baseUrlCtrl = TextEditingController(text: OrionService.defaultBaseUrl);
  final _tokenCtrl = TextEditingController();
  final _repoCtrl = TextEditingController(text: UpdateService.defaultRepo);
  final _ghTokenCtrl = TextEditingController();
  OrionActivationMode _activationMode = OrionActivationMode.alwaysOpen;
  String _status = '';

  @override
  void initState() {
    super.initState();
    _carregarConfig();
  }

  Future<void> _carregarConfig() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _baseUrlCtrl.text = OrionService.normalizeBaseUrl(
        prefs.getString('orion_base_url') ?? OrionService.defaultBaseUrl,
      );
      _tokenCtrl.text = prefs.getString('orion_token') ?? '';
      final repo = (prefs.getString('orion_update_repo') ?? '').trim();
      _repoCtrl.text = repo.isEmpty ? UpdateService.defaultRepo : repo;
      _ghTokenCtrl.text = prefs.getString('orion_update_token') ?? '';
      _activationMode = OrionActivationMode.fromWire(
        prefs.getString('orion_activation_mode'),
      );
    });
  }

  Future<void> _salvar() async {
    final normalizedUrl = OrionService.normalizeBaseUrl(_baseUrlCtrl.text);
    await OrionService.salvarConfig(
      baseUrl: normalizedUrl,
      token: _tokenCtrl.text.trim(),
    );
    await _salvarModoAtivacao(_activationMode);
    await UpdateService.salvarConfig(
      repo: _repoCtrl.text,
      token: _ghTokenCtrl.text,
    );
    setState(() {
      _baseUrlCtrl.text = normalizedUrl;
      _status = 'Salvo.';
    });
  }

  Future<void> _salvarModoAtivacao(OrionActivationMode mode) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('orion_activation_mode', mode.wireName);
  }

  Future<void> _testar() async {
    setState(() => _status = 'Testando...');
    await _salvar();
    if (OrionService.looksLikeHudUrl(_baseUrlCtrl.text)) {
      setState(() => _status = 'Use a URL do Core, sem :3001.');
      return;
    }
    final ok = await OrionService.isOnline();
    setState(() => _status = ok ? '✅ PC online' : '❌ PC offline');
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0A0A0A),
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        title: const Text(
          'Configurações',
          style: TextStyle(color: Color(0xFF00D4FF), letterSpacing: 2),
        ),
      ),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _campo('URL do Orion Core', _baseUrlCtrl),
            const SizedBox(height: 16),
            _campo('Token (opcional)', _tokenCtrl, obscuro: false),
            const SizedBox(height: 20),
            const Text(
              'Modo de voz',
              style: TextStyle(color: Color(0xFF636366), letterSpacing: 1),
            ),
            const SizedBox(height: 10),
            SegmentedButton<OrionActivationMode>(
              segments: const [
                ButtonSegment(
                  value: OrionActivationMode.alwaysOpen,
                  label: Text('Sempre aberto'),
                ),
                ButtonSegment(
                  value: OrionActivationMode.wakeWord,
                  label: Text('Exigir Orion'),
                ),
              ],
              selected: {_activationMode},
              onSelectionChanged: (value) {
                setState(() => _activationMode = value.first);
              },
              style: ButtonStyle(
                foregroundColor: WidgetStateProperty.resolveWith(
                  (states) => states.contains(WidgetState.selected)
                      ? Colors.black
                      : const Color(0xFF00D4FF),
                ),
                backgroundColor: WidgetStateProperty.resolveWith(
                  (states) => states.contains(WidgetState.selected)
                      ? const Color(0xFF00D4FF)
                      : Colors.transparent,
                ),
              ),
            ),
            const SizedBox(height: 24),
            const Divider(color: Color(0xFF2C2C2E)),
            const SizedBox(height: 8),
            const Text(
              'Atualizações',
              style: TextStyle(color: Color(0xFF636366), letterSpacing: 1),
            ),
            const SizedBox(height: 12),
            _campo('Repositório GitHub (owner/repo)', _repoCtrl),
            const SizedBox(height: 16),
            _campo(
              'Token GitHub (repo privado, opcional)',
              _ghTokenCtrl,
              obscuro: true,
            ),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              onPressed: () async {
                await _salvar();
                if (!context.mounted) return;
                await checkAndPromptUpdate(context, announceWhenNone: true);
              },
              icon: const Icon(Icons.system_update_outlined),
              style: OutlinedButton.styleFrom(
                foregroundColor: const Color(0xFF00D4FF),
                side: const BorderSide(color: Color(0xFF2C2C2E)),
                padding: const EdgeInsets.symmetric(vertical: 14),
              ),
              label: const Text('Buscar atualização'),
            ),
            const SizedBox(height: 32),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: _testar,
                    style: OutlinedButton.styleFrom(
                      foregroundColor: const Color(0xFF00D4FF),
                      side: const BorderSide(color: Color(0xFF00D4FF)),
                    ),
                    child: const Text('Testar conexão'),
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: ElevatedButton(
                    onPressed: _salvar,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF00D4FF),
                      foregroundColor: Colors.black,
                    ),
                    child: const Text('Salvar'),
                  ),
                ),
              ],
            ),
            if (_status.isNotEmpty) ...[
              const SizedBox(height: 16),
              Text(
                _status,
                textAlign: TextAlign.center,
                style: const TextStyle(color: Color(0xFF8E8E93)),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _campo(
    String label,
    TextEditingController ctrl, {
    TextInputType tipo = TextInputType.text,
    bool obscuro = false,
  }) {
    return TextField(
      controller: ctrl,
      keyboardType: tipo,
      obscureText: obscuro,
      style: const TextStyle(color: Colors.white),
      decoration: InputDecoration(
        labelText: label,
        labelStyle: const TextStyle(color: Color(0xFF636366)),
        enabledBorder: const OutlineInputBorder(
          borderSide: BorderSide(color: Color(0xFF2C2C2E)),
        ),
        focusedBorder: const OutlineInputBorder(
          borderSide: BorderSide(color: Color(0xFF00D4FF)),
        ),
      ),
    );
  }
}
