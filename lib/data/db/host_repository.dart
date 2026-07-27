import 'package:sqflite/sqflite.dart';

import 'package:mobilecode/data/db/app_database.dart';
import 'package:mobilecode/data/models/host.dart';
import 'package:mobilecode/data/secure/credential_store.dart';

abstract class HostRepository {
  Future<List<HostConfig>> list();
  Future<HostConfig?> find(String id);
  Future<void> save(HostConfig host);

  /// Deletes the host, its pinned key, and its stored secret. All three must
  /// go together — an orphaned private key in the Keychain is a liability the
  /// user believes they deleted.
  Future<void> delete(String id);
}

class SqliteHostRepository implements HostRepository {
  SqliteHostRepository(this._database, this._credentials);

  final AppDatabase _database;
  final CredentialStore _credentials;

  @override
  Future<List<HostConfig>> list() async {
    final rows = await _database.db.query('hosts', orderBy: 'label COLLATE NOCASE');
    return rows.map(HostConfig.fromRow).toList();
  }

  @override
  Future<HostConfig?> find(String id) async {
    final rows = await _database.db.query(
      'hosts',
      where: 'id = ?',
      whereArgs: [id],
      limit: 1,
    );
    return rows.isEmpty ? null : HostConfig.fromRow(rows.first);
  }

  @override
  Future<void> save(HostConfig host) async {
    await _database.db.insert(
      'hosts',
      host.toRow(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  @override
  Future<void> delete(String id) async {
    // known_hosts cascades via the foreign key; the secure store does not,
    // so clear it explicitly.
    await _database.db.delete('hosts', where: 'id = ?', whereArgs: [id]);
    await _credentials.delete(CredentialStore.hostCredentialRef(id));
    await _credentials.delete(CredentialStore.hostPassphraseRef(id));
  }
}
