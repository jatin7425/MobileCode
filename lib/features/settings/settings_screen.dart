import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        padding: EdgeInsets.fromLTRB(
          16, 16, 16, 16 + MediaQuery.viewPaddingOf(context).bottom),
        children: const [_VersionLine()],
      ),
    );
  }
}

/// Shows the installed version.
///
/// Worth having because APKs are sideloaded here rather than delivered by a
/// store: two builds look identical on the home screen, and the build number
/// is the only way to tell which CI run a phone is actually running.
class _VersionLine extends StatelessWidget {
  const _VersionLine();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return FutureBuilder<PackageInfo>(
      future: PackageInfo.fromPlatform(),
      builder: (context, snapshot) {
        final info = snapshot.data;
        return Text(
          info == null
              ? 'MobileCode'
              : 'MobileCode ${info.version} (build ${info.buildNumber})',
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        );
      },
    );
  }
}
