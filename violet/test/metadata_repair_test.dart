import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:violet/services/metadata_repair.dart';

void main() {
  test('normalizes tags without accepting placeholders or delimiters', () {
    expect(
      MetadataRepair.cleanTags(['  a name ', 'a name', 'N/A', '|bad|', null]),
      ['a name'],
    );
    expect(MetadataRepair.missing('|N/A|'), true);
  });

  test('pending and acknowledged repairs survive older snapshots', () async {
    sqfliteFfiInit();
    final queue = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    final db = await databaseFactoryFfi.openDatabase(
      inMemoryDatabasePath,
      options: OpenDatabaseOptions(singleInstance: false),
    );
    try {
      await queue.execute(
        'CREATE TABLE MetadataRepairQueue (Key TEXT PRIMARY KEY, Server TEXT, Payload TEXT, Acknowledged INTEGER)',
      );
      await db.execute(
        'CREATE TABLE HitomiColumnModel (Id INTEGER PRIMARY KEY, Files INTEGER, Language TEXT, Artists TEXT, "Groups" TEXT, EHash TEXT, ExistOnHitomi INTEGER)',
      );
      await db.execute(
        "INSERT INTO HitomiColumnModel VALUES (1,20,'korean','|N/A|','|keep|',NULL,1)",
      );
      await queue.insert('MetadataRepairQueue', {
        'Key': '1',
        'Server': 'pi',
        'Acknowledged': 1,
        'Payload': jsonEncode({
          'id': 1,
          'pages': 20,
          'source': 'hitomi',
          'token': null,
          'artists': ['new'],
          'groups': ['not replacement'],
        }),
      });
      await MetadataRepair.replaySnapshot(db, 'pi', queueDb: queue);
      expect(
        (await db.rawQuery(
          'SELECT Artists, "Groups" FROM HitomiColumnModel',
        )).single,
        {'Artists': '|new|', 'Groups': '|keep|'},
      );
      expect(
        (await queue.query('MetadataRepairQueue')).single['Acknowledged'],
        0,
      );
      await queue.update('MetadataRepairQueue', {'Acknowledged': 1});
      await MetadataRepair.replaySnapshot(
        db,
        'pi',
        queueDb: queue,
        fresh: false,
      );
      expect(await queue.query('MetadataRepairQueue'), hasLength(1));
      await MetadataRepair.replaySnapshot(db, 'pi', queueDb: queue);
      expect(await queue.query('MetadataRepairQueue'), isEmpty);
    } finally {
      await db.close();
      await queue.close();
    }
  });
}
