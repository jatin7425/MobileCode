import 'package:sqflite/sqflite.dart';

import 'package:mobilecode/data/db/app_database.dart';

/// Key/value store for non-secret configuration.
///
/// Anything secret belongs in the credential store instead — rows here end up
/// in the database file and therefore in a device backup.
class SettingsRepository {
  SettingsRepository(this._database);

  final AppDatabase _database;

  /// Base URL of the NVCF speech function, e.g.
  /// `https://<uuid>.invocation.api.nvcf.nvidia.com`.
  static const voiceEndpoint = 'voice.endpoint';

  /// Set once the starter personas have been written. Versioned so a future
  /// release can add seeds without resurrecting the ones already deleted.
  static const personasSeeded = 'voice.personas.seeded.v1';

  Future<String?> read(String key) async {
    final rows = await _database.db.query(
      'app_settings',
      where: 'key = ?',
      whereArgs: [key],
      limit: 1,
    );
    return rows.isEmpty ? null : rows.first['value'] as String?;
  }

  Future<void> write(String key, String value) async {
    await _database.db.insert(
      'app_settings',
      {'key': key, 'value': value},
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<void> delete(String key) =>
      _database.db.delete('app_settings', where: 'key = ?', whereArgs: [key]);
}
