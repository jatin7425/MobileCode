import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:mobilecode/app/providers.dart';
import 'package:mobilecode/app/home_shell.dart';

class MobileCodeApp extends ConsumerWidget {
  const MobileCodeApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return MaterialApp(
      title: 'MobileCode',
      debugShowCheckedModeBanner: false,
      navigatorKey: ref.watch(navigatorKeyProvider),
      theme: _theme(Brightness.light),
      darkTheme: _theme(Brightness.dark),
      home: const HomeShell(),
    );
  }

  ThemeData _theme(Brightness brightness) {
    return ThemeData(
      brightness: brightness,
      colorSchemeSeed: const Color(0xFF3B6EA5),
      useMaterial3: true,
    );
  }
}
