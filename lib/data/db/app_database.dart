import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

/// Local store for non-secret records: hosts, pinned host keys, session
/// bookkeeping. Secrets live in the platform secure store, never here.
class AppDatabase {
  AppDatabase._(this.db);

  final Database db;

  static const _fileName = 'mobilecode.db';
  static const _version = 1;

  static Future<AppDatabase> open() async {
    final path = p.join(await getDatabasesPath(), _fileName);
    final db = await openDatabase(
      path,
      version: _version,
      onConfigure: (db) => db.execute('PRAGMA foreign_keys = ON'),
      onCreate: _createSchema,
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
        working_directory TEXT
      )
    ''');

    await db.execute('''
      CREATE TABLE known_hosts (
        host_id     TEXT PRIMARY KEY REFERENCES hosts(id) ON DELETE CASCADE,
        key_type    TEXT NOT NULL,
        fingerprint TEXT NOT NULL,
        first_seen  INTEGER NOT NULL
      )
    ''');
  }

  Future<void> close() => db.close();
}
