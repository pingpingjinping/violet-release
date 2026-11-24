import sqlite3
import sys
from pathlib import Path
import unittest
from unittest.mock import Mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'mobile-db'))
from metadata_repair import apply_repairs, handle_metadata_repair


class MetadataRepairTests(unittest.TestCase):
    def setUp(self):
        self.db = sqlite3.connect(':memory:')
        self.db.executescript("""
          CREATE TABLE HitomiColumnModel(
            Id INTEGER PRIMARY KEY, Files INTEGER, Language TEXT, Artists TEXT,
            "Groups" TEXT, EHash TEXT, ExistOnHitomi INTEGER, Tags TEXT, Series TEXT, Characters TEXT);
          CREATE VIRTUAL TABLE FtsTags USING fts5(Tags, Artists, Groups_, Series, Characters);
          INSERT INTO HitomiColumnModel VALUES
            (1,20,'korean','|N/A|',NULL,NULL,1,NULL,NULL,NULL),
            (2,20,'korean','|keep|',NULL,'abcdef0123',0,NULL,NULL,NULL),
            (3,20,'korean',NULL,NULL,'abcdef0123',0,'|expunged|',NULL,NULL),
            (4,20,'english',NULL,NULL,NULL,1,NULL,NULL,NULL);
        """)

    def tearDown(self):
        self.db.close()

    def item(self, gid=1, **kwargs):
        return dict(dict(id=gid, pages=20, source='hitomi', token=None,
                         artists=['new artist'], groups=['new group']), **kwargs)

    def test_fill_and_preserve(self):
        items = [self.item(), self.item(2, source='eh', token='abcdef0123'),
                 self.item(3, source='eh', token='abcdef0123')]
        self.assertEqual(apply_repairs(self.db, items), ['applied'] * 3)
        self.assertEqual(self.db.execute('SELECT Artists, "Groups" FROM HitomiColumnModel WHERE Id=2').fetchone(),
                         ('|keep|', '|new group|'))
        self.assertEqual(self.db.execute('SELECT rowid, Artists, Groups_ FROM FtsTags ORDER BY rowid').fetchall(),
                         [(1,'new_artist','new_group'), (3,'new_artist','new_group')])
        self.assertEqual(apply_repairs(self.db, items), ['unchanged'] * 3)

    def test_identity_checks(self):
        items = [self.item(pages=21), self.item(2), self.item(3, source='eh', token='0000000000'), self.item(4)]
        self.assertEqual(apply_repairs(self.db, items), ['identity_changed'] * 4)

    def test_reject_invalid_batch(self):
        with self.assertRaises(ValueError):
            apply_repairs(self.db, [self.item(), self.item(artists=['bad|tag'])])
        self.assertEqual(self.db.execute('SELECT Artists FROM HitomiColumnModel WHERE Id=1').fetchone()[0], '|N/A|')

    def test_rollback(self):
        self.db.execute('CREATE TRIGGER fail BEFORE UPDATE ON HitomiColumnModel WHEN NEW.Id=2 BEGIN SELECT RAISE(ABORT,"fail"); END')
        with self.assertRaises(sqlite3.Error):
            apply_repairs(self.db, [self.item(), self.item(2, source='eh', token='abcdef0123')])
        self.assertEqual(self.db.execute('SELECT Artists FROM HitomiColumnModel WHERE Id=1').fetchone()[0], '|N/A|')
        self.assertEqual(self.db.execute('SELECT COUNT(*) FROM FtsTags').fetchone()[0], 0)

    def test_auth(self):
        handler = Mock()
        handler.headers = {'X-Violet-Sync-Token': 'wrong'}
        store = Mock(token='secret')
        handle_metadata_repair(handler, store)
        handler.send_error.assert_called_once_with(401)
        handler.rfile.read.assert_not_called()


if __name__ == '__main__':
    unittest.main()
