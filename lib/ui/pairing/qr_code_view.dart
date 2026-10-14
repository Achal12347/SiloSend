import 'package:flutter/material.dart';
import 'package:qr/qr.dart';

/// Renders [data] as a QR code.
///
/// Always dark modules on a light ground with a 4-module quiet zone, in both
/// themes: scanners need that contrast, and an inverted code in dark mode is a
/// common reason codes fail to read.
class QrCodeView extends StatelessWidget {
  final String data;
  final double size;

  const QrCodeView({super.key, required this.data, this.size = 260});

  static const Color ink = Color(0xFF16171A);
  static const Color paper = Color(0xFFFBFAF7);

  @override
  Widget build(BuildContext context) {
    final code = QrCode(
      payload: QrPayload.fromString(data),
      errorCorrectLevel: QrErrorCorrectLevel.medium,
    );
    final image = QrImage(code);
    return Semantics(
      label: 'Pairing QR code',
      image: true,
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          color: paper,
          borderRadius: BorderRadius.circular(24),
        ),
        child: CustomPaint(painter: _QrPainter(image)),
      ),
    );
  }
}

class _QrPainter extends CustomPainter {
  final QrImage image;

  _QrPainter(this.image);

  @override
  void paint(Canvas canvas, Size size) {
    const quietZone = 4;
    final count = image.moduleCount;
    final cell = size.width / (count + quietZone * 2);
    final paint = Paint()
      ..color = QrCodeView.ink
      ..isAntiAlias = false;
    for (var row = 0; row < count; row++) {
      for (var col = 0; col < count; col++) {
        if (!image.isDark(row, col)) continue;
        canvas.drawRect(
          Rect.fromLTWH(
            (col + quietZone) * cell,
            (row + quietZone) * cell,
            cell + 0.4, // slight overlap avoids hairline seams between modules
            cell + 0.4,
          ),
          paint,
        );
      }
    }
  }

  @override
  bool shouldRepaint(_QrPainter oldDelegate) => oldDelegate.image != image;
}
