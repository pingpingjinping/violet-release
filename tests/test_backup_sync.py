import gzip
import hashlib
import io
import json
from pathlib import Path
import sys
import tempfile
import threading
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.error import HTTPError
from urllib.request import Request, urlopen
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'mobile-db'))
from bookmark_sync import BookmarkStore
from backup_store import BackupStore
import backup_store

class BackupTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.sync = BookmarkStore(self.temp.name)
        self.store = BackupStore(self.sync)

    def tearDown(self):
        self.temp.cleanup()

    def test_full_history_over_10000_records_round_trips(self):
        payload = {'schema': 1, 'userAppId': 'test-app-id', 'tables': {
            'ArticleReadLog': [{'Id': i, 'Article': str(i % 100), 'LastPage': 5}
                               for i in range(1, 15002)]}}
        raw = json.dumps(payload).encode()
        data = gzip.compress(raw)
        saved = self.store.save(io.BytesIO(data), len(data), 'test-app-id')
        path = self.store.root / (saved['id'] + '.json.gz')
        self.assertEqual(json.loads(gzip.decompress(path.read_bytes())), payload)
        self.assertEqual(saved['rawSize'], len(raw))
        self.assertEqual(saved['sha256'], hashlib.sha256(data).hexdigest())
        self.assertEqual(self.store.listing()[0]['userAppId'], 'test-app-id')

    def test_bad_truncated_and_oversized_backups_leave_no_partial_files(self):
        for data, size in [(b'not gzip', 8), (gzip.compress(b'hello')[:-3], 22),
                           (gzip.compress(b'hello'), 500), (b'x', 0)]:
            with self.assertRaises((ValueError, OSError, EOFError)):
                self.store.save(io.BytesIO(data), size, 'test-id')
        with patch.object(backup_store, 'MAX_RAW', 32):
            data = gzip.compress(b'x' * 1000)
            with self.assertRaises(ValueError):
                self.store.save(io.BytesIO(data), len(data), 'test-id')
        self.assertEqual(list(self.store.root.iterdir()), [])
        self.assertEqual(self.store.listing(), [])

    def test_versions_are_immutable_and_ids_cannot_traverse_paths(self):
        data = gzip.compress(b'{}')
        first = self.store.save(io.BytesIO(data), len(data), 'same-id')
        second = self.store.save(io.BytesIO(data), len(data), 'same-id')
        self.assertNotEqual(first['id'], second['id'])
        self.assertEqual(len(self.store.listing()), 2)
        with self.assertRaises(ValueError): self.store.get('../../sync-token.txt')

    def test_http_auth_upload_listing_and_download(self):
        store = self.store
        class Handler(BaseHTTPRequestHandler):
            def do_GET(self): store.handle(self)
            def do_POST(self): store.handle(self)
            def log_message(self, *args): pass
        server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        base = f'http://127.0.0.1:{server.server_port}/api/backups'
        data = gzip.compress(b'{"schema":1}')
        headers = {'X-Violet-Sync-Token': self.sync.token, 'X-Violet-User-App-Id': 'test-id'}
        try:
            with self.assertRaises(HTTPError) as error: urlopen(base, timeout=3)
            self.assertEqual(error.exception.code, 401)
            with urlopen(Request(base, data=data, headers=headers), timeout=3) as response:
                meta = json.load(response)
            with urlopen(Request(base, headers=headers), timeout=3) as response:
                self.assertEqual(json.load(response)['backups'][0]['id'], meta['id'])
            with self.assertRaises(HTTPError) as error: urlopen(base + '/' + meta['id'], timeout=3)
            self.assertEqual(error.exception.code, 401)
            with urlopen(Request(base + '/' + meta['id'], headers=headers), timeout=3) as response:
                self.assertEqual(response.read(), data)
        finally:
            server.shutdown(); server.server_close(); thread.join()

if __name__ == '__main__': unittest.main()
