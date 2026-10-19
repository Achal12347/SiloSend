import 'package:flutter/material.dart';

import 'package:vayu/core/state/app_container.dart';
import 'package:vayu/ui/profile/profile_widgets.dart';
import 'package:vayu/ui/settings/settings_page.dart';

/// Profile and Settings, top right of every main tab.
List<Widget> primaryAppBarActions(
  BuildContext context,
  AppContainer container,
) => [
  ProfileButton(container: container),
  IconButton(
    icon: const Icon(Icons.settings_outlined),
    tooltip: 'Settings',
    onPressed: () => Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => SettingsPage(container: container)),
    ),
  ),
  const SizedBox(width: 8),
];
