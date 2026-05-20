import 'dart:math' as math;
import 'dart:ui' show lerpDouble;
import 'package:flutter/material.dart';

/// Visualizador de áudio estilo equalizador que reage à fala.
/// [level] devolve o nível de áudio atual (0..1); [active] liga a animação.
class OrionWaveform extends StatefulWidget {
  final double Function() level;
  final bool active;
  final Color color;
  final int bars;
  final double height;

  const OrionWaveform({
    super.key,
    required this.level,
    required this.active,
    this.color = const Color(0xFF00D4FF),
    this.bars = 21,
    this.height = 64,
  });

  @override
  State<OrionWaveform> createState() => _OrionWaveformState();
}

class _OrionWaveformState extends State<OrionWaveform>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;
  double _display = 0;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1400),
    )..repeat();
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: widget.height,
      width: double.infinity,
      child: AnimatedBuilder(
        animation: _ctrl,
        builder: (_, _) {
          final target = widget.active ? widget.level().clamp(0.0, 1.0) : 0.0;
          // Suaviza a transição do nível para a onda não ficar "nervosa".
          _display = lerpDouble(_display, target, 0.18) ?? target;
          return CustomPaint(
            painter: _WavePainter(
              phase: _ctrl.value * 2 * math.pi,
              level: _display,
              active: widget.active,
              color: widget.color,
              bars: widget.bars,
            ),
          );
        },
      ),
    );
  }
}

class _WavePainter extends CustomPainter {
  final double phase;
  final double level;
  final bool active;
  final Color color;
  final int bars;

  _WavePainter({
    required this.phase,
    required this.level,
    required this.active,
    required this.color,
    required this.bars,
  });

  @override
  void paint(Canvas canvas, Size size) {
    const idle = 0.10; // altura mínima (estado calmo)
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.fill;
    final glow = Paint()
      ..color = color.withValues(alpha: 0.35)
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 6);

    final barWidth = size.width / (bars * 2);
    final centerY = size.height / 2;
    final maxBar = size.height * 0.92;

    for (var i = 0; i < bars; i++) {
      final t = bars == 1 ? 0.5 : i / (bars - 1); // 0..1
      // Envelope: barras do centro mais altas que as das pontas.
      final envelope = math.sin(t * math.pi);
      final wave = 0.5 + 0.5 * math.sin(phase * 1.6 + i * 0.55);
      final amp = active
          ? idle + (0.18 + level * 0.9) * envelope * wave
          : idle * (0.6 + 0.4 * envelope);
      final h = (maxBar * amp).clamp(barWidth, maxBar);
      final x = size.width * t;
      final rect = RRect.fromRectAndRadius(
        Rect.fromCenter(center: Offset(x, centerY), width: barWidth, height: h),
        Radius.circular(barWidth),
      );
      canvas.drawRRect(rect, glow);
      canvas.drawRRect(rect, paint);
    }
  }

  @override
  bool shouldRepaint(covariant _WavePainter old) =>
      old.phase != phase || old.level != level || old.active != active;
}
