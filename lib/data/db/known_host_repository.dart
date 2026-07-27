import 'package:sqflite/sqflite.dart';

import 'package:mobilecode/data/db/app_database.dart';
import 'package:mobilecode/data/models/known_host.dart';

/// Pinned host keys, in the spirit of `~/.ssh/known_hosts`.
abstract class KnownHostRepository {
  Future<KnownHost?> find(String hostId);
  Future<void> pin(KnownHost host);

  /// Removes a pin. Only ever called from an explicit user action in settings
  /// — never automatically in response to a mismatch.
  Future<void> unpin(String hostId);
}

class SqliteKnownHostRepository implements KnownHostRepository {
  SqliteKnownHostRepository(this._database);

  final AppDatabase _database;

  @override
  Future<KnownHost?> find(String hostId) async {
    final rows = await _database.db.query(
      'known_hosts',
      where: 'host_id = ?',
      whereArgs: [hostId],
      limit: 1,
    );
    return rows.isEmpty ? null : KnownHost.fromRow(rows.first);
  }

  @override
  Future<void> pin(KnownHost host) async {
    await _database.db.insert(
      'known_hosts',
      host.toRow(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  @override
  Future<void> unpin(String hostId) async {
    await _database.db.delete(
      'known_hosts',
      where: 'host_id = ?',
      whereArgs: [hostId],
    );
  }
}

/// In-memory implementation for tests.
class InMemoryKnownHostRepository implements KnownHostRepository {
  final _pins = <String, KnownHost>{};

  @override
  Future<KnownHost?> find(String hostId) async => _pins[hostId];

  @override
  Future<void> pin(KnownHost host) async => _pins[host.hostId] = host;

  @override
  Future<void> unpin(String hostId) async => _pins.remove(hostId);
}
