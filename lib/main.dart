import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:mobilecode/app/app.dart';
import 'package:mobilecode/app/providers.dart';
import 'package:mobilecode/data/db/app_database.dart';
import 'package:mobilecode/data/db/host_repository.dart';
import 'package:mobilecode/data/db/known_host_repository.dart';
import 'package:mobilecode/data/secure/credential_store.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  final database = await AppDatabase.open();
  final credentials = SecureCredentialStore();

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
      ],
      child: const MobileCodeApp(),
    ),
  );
}
