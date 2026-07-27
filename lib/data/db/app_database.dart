import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

/// Local store for non-secret records: hosts, pinned host keys, session
/// bookkeeping. Secrets live in the platform secure store, never here.
class AppDatabase {
  AppDatabase._(this.db);

  final Database db;

  static const _fileName = 'mobilecode.db';
  static const _version = 3;

  static Future<AppDatabase> open() async {
    final path = p.join(await getDatabasesPath(), _fileName);
    final db = await openDatabase(
      path,
      version: _version,
      onCreate: _createSchema,
      onUpgrade: _upgrade,
    );
    return AppDatabase._(db);
  }

  static Future<void> _createSchema(Database db, int version) async {
    await db.execute('''
      CREATE TABLE hosts (
        id                TEXT PRIMARY KEY,
        label             TEXT NOT NULL,
        hostname          TEXT NOT NULL,
        port              INTEGER NOT NULL DEFAULT 22,
        username          TEXT NOT NULL,
        auth_method       TEXT NOT NULL,
        credential_ref    TEXT,
        working_directory TEXT,
        websocket_url     TEXT
      )
    ''');

    // Deliberately no foreign key to hosts, so a pin can exist for a host that
    // is not a row here — transient targets still need their key checked.
    await db.execute('''
      CREATE TABLE known_hosts (
        host_id     TEXT PRIMARY KEY,
        key_type    TEXT NOT NULL,
        fingerprint TEXT NOT NULL,
        first_seen  INTEGER NOT NULL
      )
    ''');

    await _createVoiceTables(db);
  }

  /// Personas and the endpoint they speak through. Split out so the v3
  /// migration and a fresh install build exactly the same schema.
  static Future<void> _createVoiceTables(Database db) async {
    await db.execute('''
      CREATE TABLE personas (
        id              TEXT PRIMARY KEY,
        name            TEXT NOT NULL,
        role            TEXT NOT NULL DEFAULT '',
        voice_key       TEXT,
        default_emotion TEXT NOT NULL DEFAULT 'Neutral'
      )
    ''');

    // Non-secret configuration only. The API key lives in the secure store;
    // putting it here would place it in the database backup.
    await db.execute('''
      CREATE TABLE app_settings (
        key   TEXT PRIMARY KEY,
        value TEXT NOT NULL
      )
    ''');
  }

  static Future<void> _upgrade(Database db, int from, int to) async {
    if (from < 2) {
      await db.execute('ALTER TABLE hosts ADD COLUMN websocket_url TEXT');

      // SQLite cannot drop a foreign key in place, so rebuild the table.
      // Pins are security state — losing them would silently re-trust a
      // changed host key — so the rows are copied, not recreated.
      await db.execute('ALTER TABLE known_hosts RENAME TO known_hosts_v1');
      await db.execute('''
        CREATE TABLE known_hosts (
          host_id     TEXT PRIMARY KEY,
          key_type    TEXT NOT NULL,
          fingerprint TEXT NOT NULL,
          first_seen  INTEGER NOT NULL
        )
      ''');
      await db.execute('''
        INSERT INTO known_hosts (host_id, key_type, fingerprint, first_seen)
        SELECT host_id, key_type, fingerprint, first_seen FROM known_hosts_v1
      ''');
      await db.execute('DROP TABLE known_hosts_v1');
    }
    if (from < 3) {
      await _createVoiceTables(db);
    }
  }

  Future<void> close() => db.close();
}
