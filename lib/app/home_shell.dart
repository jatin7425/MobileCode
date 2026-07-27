import 'package:flutter/material.dart';

import 'package:mobilecode/features/codespaces/codespaces_screen.dart';
import 'package:mobilecode/features/hosts/hosts_screen.dart';
import 'package:mobilecode/features/settings/settings_screen.dart';

/// Top-level navigation.
///
/// Hosts and Codespaces are separate destinations rather than one merged list:
/// a host is something the user owns and configures once, while a Codespace is
/// disposable and comes and goes with GitHub. Mixing them would make the list
/// unstable for no gain.
class HomeShell extends StatefulWidget {
  const HomeShell({super.key});

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  var _index = 0;

  static const _screens = [
    HostsScreen(),
    CodespacesScreen(),
    SettingsScreen(),
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      // IndexedStack keeps each tab's state alive, so switching away from a
      // loaded Codespace list and back does not refetch it.
      body: IndexedStack(index: _index, children: _screens),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: (i) => setState(() => _index = i),
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.dns_outlined),
            selectedIcon: Icon(Icons.dns),
            label: 'Hosts',
          ),
          NavigationDestination(
            icon: Icon(Icons.cloud_outlined),
            selectedIcon: Icon(Icons.cloud),
            label: 'Codespaces',
          ),
          NavigationDestination(
            icon: Icon(Icons.settings_outlined),
            selectedIcon: Icon(Icons.settings),
            label: 'Settings',
          ),
        ],
      ),
    );
  }
}
