import 'package:flutter/material.dart';
import 'services/update_service.dart';

/// Verifica se há atualização e, se houver, oferece baixar e instalar.
/// [announceWhenNone] mostra um aviso quando já está na versão mais recente
/// (útil no botão manual das Configurações).
Future<void> checkAndPromptUpdate(
  BuildContext context, {
  bool announceWhenNone = false,
}) async {
  final update = await UpdateService.checkForUpdate();
  if (!context.mounted) return;

  if (update == null) {
    if (announceWhenNone) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Você já está na versão mais recente.')),
      );
    }
    return;
  }

  final aceitar = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      backgroundColor: const Color(0xFF1C1C1E),
      title: const Text(
        'Atualização pronta para instalação',
        style: TextStyle(color: Colors.white),
      ),
      content: SingleChildScrollView(
        child: Text(
          'A versão ${update.version} do Orion está disponível.\n\n'
          'Foram aplicadas melhorias internas, correções e otimizações '
          'para uma resposta mais fluida do assistente.\n\n'
          'Recomendo atualizar para manter o Orion na melhor versão.',
          style: const TextStyle(color: Color(0xFF8E8E93)),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx, false),
          child: const Text(
            'Ignorar por enquanto',
            style: TextStyle(color: Color(0xFF8E8E93)),
          ),
        ),
        ElevatedButton(
          style: ElevatedButton.styleFrom(
            backgroundColor: const Color(0xFF00D4FF),
            foregroundColor: Colors.black,
          ),
          onPressed: () => Navigator.pop(ctx, true),
          child: const Text('Atualizar Orion'),
        ),
      ],
    ),
  );

  if (aceitar != true || !context.mounted) return;
  await _baixarEInstalar(context, update);
}

Future<void> _baixarEInstalar(BuildContext context, AppUpdate update) async {
  // Sem permissão "Instalar apps desconhecidos" → leva o usuário às configurações.
  if (!await UpdateService.canInstall()) {
    if (!context.mounted) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1C1C1E),
        title: const Text(
          'Permissão necessária',
          style: TextStyle(color: Colors.white),
        ),
        content: const Text(
          'Para instalar a atualização, ative "Instalar apps desconhecidos" '
          'para o Orion nas próximas telas.',
          style: TextStyle(color: Color(0xFF8E8E93)),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text(
              'Cancelar',
              style: TextStyle(color: Color(0xFF8E8E93)),
            ),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF00D4FF),
              foregroundColor: Colors.black,
            ),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Abrir configurações'),
          ),
        ],
      ),
    );
    if (ok == true) await UpdateService.openInstallSettings();
    return;
  }

  if (!context.mounted) return;
  final progress = ValueNotifier<double>(0);
  showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (_) => AlertDialog(
      backgroundColor: const Color(0xFF1C1C1E),
      title: const Text(
        'Baixando atualização',
        style: TextStyle(color: Colors.white),
      ),
      content: ValueListenableBuilder<double>(
        valueListenable: progress,
        builder: (_, value, _) => Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            LinearProgressIndicator(
              value: value == 0 ? null : value,
              backgroundColor: const Color(0xFF2C2C2E),
              color: const Color(0xFF00D4FF),
            ),
            const SizedBox(height: 12),
            Text(
              '${(value * 100).toStringAsFixed(0)}%',
              style: const TextStyle(color: Color(0xFF8E8E93)),
            ),
          ],
        ),
      ),
    ),
  );

  try {
    await UpdateService.downloadAndInstall(
      update,
      onProgress: (p) => progress.value = p,
    );
  } catch (e) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Erro ao atualizar: $e')),
      );
    }
  } finally {
    if (context.mounted) {
      Navigator.of(context, rootNavigator: true).pop();
    }
    progress.dispose();
  }
}
