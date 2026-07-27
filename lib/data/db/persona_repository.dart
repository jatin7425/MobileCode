import 'package:sqflite/sqflite.dart';

import 'package:mobilecode/data/db/app_database.dart';
import 'package:mobilecode/data/models/persona.dart';

abstract class PersonaRepository {
  Future<List<Persona>> list();
  Future<void> save(Persona persona);
  Future<void> delete(String id);
}

class SqlitePersonaRepository implements PersonaRepository {
  SqlitePersonaRepository(this._database);

  final AppDatabase _database;

  @override
  Future<List<Persona>> list() async {
    final rows = await _database.db.query(
      'personas',
      orderBy: 'name COLLATE NOCASE',
    );
    return rows.map(Persona.fromRow).toList();
  }

  @override
  Future<void> save(Persona persona) async {
    await _database.db.insert(
      'personas',
      persona.toRow(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  @override
  Future<void> delete(String id) =>
      _database.db.delete('personas', where: 'id = ?', whereArgs: [id]);
}
