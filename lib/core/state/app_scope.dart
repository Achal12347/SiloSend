import 'package:flutter/widgets.dart';

import 'package:vayu/core/state/app_container.dart';

/// Provides [AppContainer] down the widget tree using standard Flutter mechanisms.
class AppScope extends InheritedWidget {
  final AppContainer container;

  const AppScope({super.key, required this.container, required super.child});

  /// Retrieves the ambient [AppContainer] from the given [context].
  static AppContainer of(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<AppScope>();
    assert(
      scope != null,
      'No AppScope found in context. Wrap widget tree in AppScope.',
    );
    return scope!.container;
  }

  /// Retrieves the ambient [AppContainer] without establishing a rebuild dependency.
  static AppContainer read(BuildContext context) {
    final scope = context.getInheritedWidgetOfExactType<AppScope>();
    assert(
      scope != null,
      'No AppScope found in context. Wrap widget tree in AppScope.',
    );
    return scope!.container;
  }

  @override
  bool updateShouldNotify(AppScope oldWidget) =>
      container != oldWidget.container;
}
