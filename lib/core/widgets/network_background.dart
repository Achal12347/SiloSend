import 'dart:math';
import 'package:flutter/material.dart';

/// A decorative background widget that draws a subtle network/grid pattern
/// with animated nodes, suitable for discovery and transfer screens.
class NetworkBackground extends StatefulWidget {
  const NetworkBackground({
    super.key,
    this.nodeCount = 12,
    this.lineColor,
    this.nodeColor,
    this.animationDuration = const Duration(seconds: 8),
  });

  final int nodeCount;
  final Color? lineColor;
  final Color? nodeColor;
  final Duration animationDuration;

  @override
  State<NetworkBackground> createState() => _NetworkBackgroundState();
}

class _NetworkBackgroundState extends State<NetworkBackground>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  final _random = Random(42);
  late List<_Node> _nodes;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: widget.animationDuration,
    )..repeat();

    _nodes = List.generate(widget.nodeCount, (i) {
      return _Node(
        x: _random.nextDouble(),
        y: _random.nextDouble(),
        phase: _random.nextDouble() * 2 * pi,
        speed: 0.3 + _random.nextDouble() * 0.7,
      );
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final lineColor =
        widget.lineColor ?? theme.colorScheme.primary.withAlpha(20);
    final nodeColor =
        widget.nodeColor ?? theme.colorScheme.primary.withAlpha(40);

    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) {
        return CustomPaint(
          painter: _NetworkPainter(
            nodes: _nodes,
            time: _controller.value,
            lineColor: lineColor,
            nodeColor: nodeColor,
          ),
          size: Size.infinite,
        );
      },
    );
  }
}

class _Node {
  final double x;
  final double y;
  final double phase;
  final double speed;

  const _Node({
    required this.x,
    required this.y,
    required this.phase,
    required this.speed,
  });
}

class _NetworkPainter extends CustomPainter {
  _NetworkPainter({
    required this.nodes,
    required this.time,
    required this.lineColor,
    required this.nodeColor,
  });

  final List<_Node> nodes;
  final double time;
  final Color lineColor;
  final Color nodeColor;

  @override
  void paint(Canvas canvas, Size size) {
    final positions = <Offset>[];

    for (final node in nodes) {
      final dx = size.width * node.x;
      final dy = size.height * node.y;
      final offset = Offset(
        dx + sin(time * node.speed * 2 * pi + node.phase) * 8,
        dy + cos(time * node.speed * 2 * pi + node.phase) * 8,
      );
      positions.add(offset);
    }

    // Draw lines between nearby nodes
    final linePaint = Paint()
      ..color = lineColor
      ..strokeWidth = 0.5
      ..style = PaintingStyle.stroke;

    for (int i = 0; i < positions.length; i++) {
      for (int j = i + 1; j < positions.length; j++) {
        final distance = (positions[i] - positions[j]).distance;
        if (distance < 120) {
          linePaint.color = lineColor.withAlpha(
            ((1 - distance / 120) * 30).round().clamp(5, 30),
          );
          canvas.drawLine(positions[i], positions[j], linePaint);
        }
      }
    }

    // Draw nodes
    final nodePaint = Paint()
      ..color = nodeColor
      ..style = PaintingStyle.fill;

    for (final pos in positions) {
      canvas.drawCircle(pos, 2.5, nodePaint);
    }
  }

  @override
  bool shouldRepaint(_NetworkPainter oldDelegate) => true;
}
