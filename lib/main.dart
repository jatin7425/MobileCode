import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:mobilecode/app/app.dart';
import 'package:mobilecode/app/providers.dart';
import 'package:mobilecode/data/db/app_database.dart';
import 'package:mobilecode/data/db/host_repository.dart';
import 'package:mobilecode/data/db/known_host_repository.dart';
import 'package:mobilecode/data/db/persona_repository.dart';
import 'package:mobilecode/data/db/settings_repository.dart';
import 'package:mobilecode/data/models/persona.dart';
import 'package:mobilecode/data/secure/credential_store.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  final database = await AppDatabase.open();
  final credentials = SecureCredentialStore();
  final personas = SqlitePersonaRepository(database);
  await _seedPersonas(personas);

  runApp(
    ProviderScope(
      overrides: [
        credentialStoreProvider.overrideWithValue(credentials),
        hostRepositoryProvider.overrideWithValue(
          SqliteHostRepository(database, credentials),
        ),
        knownHostRepositoryProvider.overrideWithValue(
          SqliteKnownHostRepository(database),
        ),
        personaRepositoryProvider.overrideWithValue(personas),
        settingsRepositoryProvider.overrideWithValue(
          SettingsRepository(database),
        ),
      ],
      child: const MobileCodeApp(),
    ),
  );
}

/// Puts the starter personas in place on first run.
///
/// Guarded on the table being empty rather than a "seeded" flag: seeding
/// unconditionally would resurrect personas the user deleted on every launch.
Future<void> _seedPersonas(PersonaRepository repository) async {
  if ((await repository.list()).isNotEmpty) return;
  for (final persona in Persona.seeds) {
    await repository.save(persona);
  }
}
