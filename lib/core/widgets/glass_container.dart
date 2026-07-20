import 'package:flutter/material.dart';
import 'package:silosend/core/theme/glass_effect.dart';

/// A glassmorphism-styled container that applies the app's frosted-glass
/// decoration with an optional backdrop blur.
class GlassContainer extends StatelessWidget {
  const GlassContainer({
    super.key,
    required this.child,
    this.padding,
    this.margin,
    this.borderRadius = 16,
    this.customDecoration,
    this.width,
    this.height,
    this.applyBlur = false,
  });

  final Widget child;
  final EdgeInsetsGeometry? padding;
  final EdgeInsetsGeometry? margin;
  final double borderRadius;
  final BoxDecoration? customDecoration;
  final double? width;
  final double? height;
  final bool applyBlur;

  @override
  Widget build(BuildContext context) {
    final decoration =
        customDecoration ??
        GlassEffect.adaptive(context, borderRadius: borderRadius);

    final container = Container(
      width: width,
      height: height,
      margin: margin,
      padding: padding ?? const EdgeInsets.all(16),
      decoration: decoration,
      child: child,
    );

    if (applyBlur) {
      return GlassEffect.blur(child: container);
    }

    return container;
  }
}
