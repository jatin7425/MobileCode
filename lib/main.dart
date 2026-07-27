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
  final settings = SettingsRepository(database);
  await _seedPersonas(personas, settings);

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
        settingsRepositoryProvider.overrideWithValue(settings),
      ],
      child: const MobileCodeApp(),
    ),
  );
}

/// Puts the starter personas in place on first run.
///
/// Guarded on a stored marker rather than on the table being empty: a user who
/// deletes every persona has expressed a preference, and an emptiness check
/// would undo it by restoring all three on the next launch. The marker is
/// written last, so a crash mid-seed retries instead of leaving a partial set.
Future<void> _seedPersonas(
  PersonaRepository repository,
  SettingsRepository settings,
) async {
  if (await settings.read(SettingsRepository.personasSeeded) != null) return;
  for (final persona in Persona.seeds) {
    await repository.save(persona);
  }
  await settings.write(SettingsRepository.personasSeeded, 'true');
}
