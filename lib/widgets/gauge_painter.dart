import 'dart:math';
import 'package:flutter/material.dart';

class GaugePainter extends CustomPainter {
  final double value;
  final double maxVal;
  final String label;
  final String unit;
  final Color baseColor;

  GaugePainter({
    required this.value,
    required this.maxVal,
    required this.label,
    required this.unit,
    required this.baseColor,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final double radius = min(size.width, size.height) / 2.0;
    final Offset center = Offset(size.width / 2.0, size.height / 2.0);

    const double startAngle = 3 * pi / 4; // 135 degrees (bottom left)
    const double totalSweep = 3 * pi / 2; // 270 degrees sweep

    // 1. Background Arc (Empty track)
    final bgPaint = Paint()
      ..color = Colors.black.withOpacity(0.06)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 10.0
      ..strokeCap = StrokeCap.round;

    canvas.drawArc(
      Rect.fromCircle(center: center, radius: radius - 10),
      startAngle,
      totalSweep,
      false,
      bgPaint,
    );

    // 2. Value Fill Arc (Active track)
    final double pct = (value / maxVal).clamp(0.0, 1.0);
    final double sweepAngle = totalSweep * pct;

    // Glowing Paint System
    final glowPaint = Paint()
      ..color = baseColor.withOpacity(0.4)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 14.0
      ..strokeCap = StrokeCap.round
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 6.0);

    final fillPaint = Paint()
      ..color = baseColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = 10.0
      ..strokeCap = StrokeCap.round;

    // Warning override for low Battery SoC or Fuel
    if ((label.toUpperCase().contains("SOC") || label.toUpperCase().contains("BATTERY") || label.toUpperCase().contains("FUEL")) && pct < 0.20) {
      fillPaint.color = Colors.redAccent;
      glowPaint.color = Colors.redAccent.withOpacity(0.4);
    }

    if (sweepAngle > 0) {
      canvas.drawArc(
        Rect.fromCircle(center: center, radius: radius - 10),
        startAngle,
        sweepAngle,
        false,
        glowPaint,
      );
      canvas.drawArc(
        Rect.fromCircle(center: center, radius: radius - 10),
        startAngle,
        sweepAngle,
        false,
        fillPaint,
      );
    }

    // 3. Ticks Drawing
    final tickPaint = Paint()
      ..color = Colors.white.withOpacity(0.15)
      ..strokeWidth = 2.0;

    const int tickCount = 13;
    for (int i = 0; i < tickCount; i++) {
      final double tickPct = i / (tickCount - 1);
      final double angle = startAngle + totalSweep * tickPct;

      final double innerR = radius - 22;
      final double outerR = radius - 15;

      // Make tick paint glowing if covered by active value fill
      if (tickPct <= pct) {
        tickPaint.color = baseColor;
      } else {
        tickPaint.color = Colors.black.withOpacity(0.12);
      }

      final Offset p1 = Offset(
        center.dx + innerR * cos(angle),
        center.dy + innerR * sin(angle),
      );
      final Offset p2 = Offset(
        center.dx + outerR * cos(angle),
        center.dy + outerR * sin(angle),
      );
      canvas.drawLine(p1, p2, tickPaint);
    }

    // 4. Value Text Drawing
    final TextPainter valText = TextPainter(
      text: TextSpan(
        text: value.round().toString(),
        style: TextStyle(
          fontFamily: 'Space Grotesk',
          fontSize: radius * 0.32,
          fontWeight: FontWeight.bold,
          color: Colors.black87,
          letterSpacing: -1,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();

    valText.paint(
      canvas,
      Offset(center.dx - valText.width / 2.0, center.dy - valText.height * 0.55),
    );

    // 5. Unit Text
    final TextPainter unitText = TextPainter(
      text: TextSpan(
        text: unit,
        style: TextStyle(
          fontSize: radius * 0.12,
          fontWeight: FontWeight.w600,
          color: Colors.black54,
          letterSpacing: 1.0,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();

    unitText.paint(
      canvas,
      Offset(center.dx - unitText.width / 2.0, center.dy + radius * 0.12),
    );

    // 6. Label Text
    final TextPainter labelText = TextPainter(
      text: TextSpan(
        text: label.toUpperCase(),
        style: TextStyle(
          fontSize: radius * 0.11,
          fontWeight: FontWeight.bold,
          color: Colors.grey[700],
          letterSpacing: 1.5,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();

    labelText.paint(
      canvas,
      Offset(center.dx - labelText.width / 2.0, center.dy + radius * 0.42),
    );
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) {
    return true;
  }
}
