import 'package:flutter/material.dart';

/// [normal], or no time at all when the user turned on Android's "Remove
/// animations". Every Vayu animation goes through this.
Duration motion(
  BuildContext context, [
  Duration normal = const Duration(milliseconds: 220),
]) => MediaQuery.of(context).disableAnimations ? Duration.zero : normal;

/// Cross-fades (with a slight scale) when [child]'s key changes: a state
/// change such as waiting → done. Give each state its own key.
class VayuSwitcher extends StatelessWidget {
  final Widget child;

  const VayuSwitcher({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    return AnimatedSwitcher(
      duration: motion(context),
      switchInCurve: Curves.easeOutCubic,
      switchOutCurve: Curves.easeInCubic,
      transitionBuilder: (child, animation) => FadeTransition(
        opacity: animation,
        child: ScaleTransition(
          scale: Tween<double>(begin: 0.94, end: 1).animate(animation),
          child: child,
        ),
      ),
      child: child,
    );
  }
}

/// Eases [child] in once (fade and a short rise), for something that just
/// arrived. [onDone] runs when it has settled.
class EaseIn extends StatelessWidget {
  final Widget child;
  final VoidCallback? onDone;

  const EaseIn({super.key, required this.child, this.onDone});

  @override
  Widget build(BuildContext context) {
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: motion(context, const Duration(milliseconds: 260)),
      curve: Curves.easeOutCubic,
      onEnd: onDone,
      builder: (context, t, child) => Opacity(
        opacity: t,
        child: Transform.translate(
          offset: Offset(0, 10 * (1 - t)),
          child: child,
        ),
      ),
      child: child,
    );
  }
}
