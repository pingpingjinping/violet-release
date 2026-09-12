import importlib.util
import os
from pathlib import Path
import sqlite3
import sys
import tempfile
import unittest

class ContentSnapshotTests(unittest.TestCase):
    def test_unchanged_snapshot_keeps_version(self):
        with tempfile.TemporaryDirectory() as task_dir:
            root = Path(task_dir)
            os.environ['VIOLET_EXPORT_ROOT'] = str(root / 'export')
            os.environ['VIOLET_SYNC_STATE'] = str(root / 'state')
            module_dir = Path(__file__).resolve().parents[1] / 'mobile-db'
            sys.path.insert(0, str(module_dir))
            spec = importlib.util.spec_from_file_location('snapshot_server', module_dir / 'server.py')
            server = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(server)
            source = root / 'source.db'
            with sqlite3.connect(source) as db:
                db.execute('CREATE TABLE HitomiColumnModel (Id INTEGER PRIMARY KEY, Language TEXT, Title TEXT)')
                db.executemany('INSERT INTO HitomiColumnModel VALUES (?, ?, ?)', [(1,'korean','first'),(2,'english','excluded')])
            original_connect = sqlite3.connect
            def connect(path, *args, **kwargs):
                if path == 'file:/content-data/data.db?mode=ro':
                    path = f'file:{source}?mode=ro'
                return original_connect(path, *args, **kwargs)
            from unittest.mock import patch
            with patch.object(server.sqlite3, 'connect', side_effect=connect):
                server.make_snapshot()
                output = server.ROOT / 'rawdata-korean.db'
                original_time = output.stat().st_mtime_ns
                server.make_snapshot()
                self.assertEqual(output.stat().st_mtime_ns, original_time)
                with original_connect(source) as db:
                    db.execute("UPDATE HitomiColumnModel SET Title='updated' WHERE Id=1")
                server.make_snapshot()
                self.assertNotEqual(output.stat().st_mtime_ns, original_time)
                with original_connect(output) as db:
                    self.assertEqual(db.execute('SELECT Id, Title FROM HitomiColumnModel').fetchall(), [(1,'updated')])
            for name in ('VIOLET_EXPORT_ROOT','VIOLET_SYNC_STATE'):
                os.environ.pop(name, None)
            sys.path.remove(str(module_dir))

if __name__ == '__main__':
    unittest.main()
