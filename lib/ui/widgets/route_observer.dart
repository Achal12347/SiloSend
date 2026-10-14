import 'package:flutter/widgets.dart';

/// Lets screens know when another screen covers them or they become visible
/// again (used to pause NFC reading on home while other screens are open).
final RouteObserver<ModalRoute<void>> vayuRouteObserver =
    RouteObserver<ModalRoute<void>>();
