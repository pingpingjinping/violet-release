import functools
import http.server
import importlib.util
import json
import os
from pathlib import Path
import sys
import tempfile
import threading
import unittest
import urllib.error
import urllib.request
import uuid

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'mobile-db'))
from bookmark_sync import BookmarkStore
from activity_sync import ActivityStore

class ActivityTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.bookmarks = BookmarkStore(Path(self.temp.name) / 'state')
        self.store = ActivityStore(self.bookmarks)
        self.app = str(uuid.uuid4())
        self.web = str(uuid.uuid4())

    def exchange(self, device=None, origin='app', read=None, download=None):
        return self.store.exchange({'device': device or self.app, 'origin': origin,
                                   'read': read or [], 'download': download or []})['records']

    def test_empty_web_pulls_app_reads_and_completed_downloads(self):
        self.exchange(read=[{'article': '1', 'timestamp': 1000, 'page': 9}],
                      download=[{'article': '2', 'timestamp': 900}])
        rows = self.exchange(self.web, 'web')
        self.assertEqual(len(rows), 2)
        self.assertEqual({r['origin'] for r in rows}, {'app'})
        self.assertEqual(next(r for r in rows if r['kind'] == 'read')['page'], 9)

    def test_both_devices_read_and_download_same_article_without_overwriting_origin(self):
        self.exchange(read=[{'article': '1', 'timestamp': 1000, 'page': 9}], download=[{'article': '1', 'timestamp': 1000}])
        rows = self.exchange(self.web, 'web', read=[{'article': '1', 'timestamp': 2000, 'page': 2}], download=[{'article': '1', 'timestamp': 2000}])
        self.assertEqual(len(rows), 4)
        self.assertEqual(rows[0]['origin'], 'web')
        self.assertEqual({r['origin'] for r in rows if r['kind'] == 'download'}, {'app', 'web'})

    def test_newer_read_can_move_backwards_and_stale_retry_cannot_overwrite_it(self):
        self.exchange(read=[{'article': '1', 'timestamp': 1000, 'page': 90}])
        self.exchange(read=[{'article': '1', 'timestamp': 2000, 'page': 2}])
        rows = self.exchange(read=[{'article': '1', 'timestamp': 1000, 'page': 90}])
        self.assertEqual(rows[0]['page'], 2)
        self.assertEqual(rows[0]['timestamp'], 2000)

    def test_retry_does_not_duplicate_records(self):
        for _ in range(3):
            rows = self.exchange(download=[{'article': '1', 'timestamp': 1000}])
        self.assertEqual(len(rows), 1)

    def test_history_survives_local_record_or_file_deletion(self):
        self.exchange(download=[{'article': '1', 'timestamp': 1000}])
        self.assertEqual(len(self.exchange()), 1)

    def test_invalid_batch_is_atomic(self):
        with self.assertRaises(ValueError):
            self.exchange(read=[{'article': '1', 'timestamp': 1000, 'page': 0}, {'article': 'bad', 'timestamp': 1000}])
        self.assertEqual(self.exchange(), [])

    def test_private_file_metadata_never_returned(self):
        rows = self.exchange(download=[{'article': '1', 'timestamp': 1000, 'Path': '/private/fixture', 'Files': ['fixture.png']}])
        self.assertNotIn('/private', json.dumps(rows))
        self.assertNotIn('Files', json.dumps(rows))

    def test_bookmark_data_and_token_are_preserved(self):
        payload = {'requestId': str(uuid.uuid4()), 'baseRevision': 0, 'add': ['1'], 'remove': []}
        self.bookmarks.exchange(payload)
        self.exchange(read=[{'article': '2', 'timestamp': 1000}])
        restarted = BookmarkStore(Path(self.temp.name) / 'state')
        self.assertEqual(restarted.token, self.bookmarks.token)
        self.assertEqual(restarted.exchange(payload)['articles'], ['1'])
        self.assertEqual(len(ActivityStore(restarted).exchange({'device': self.web, 'origin': 'web', 'read': [], 'download': []})['records']), 1)

    def test_http_authentication_cors_and_database_download_still_work(self):
        export = Path(self.temp.name) / 'export'
        export.mkdir()
        (export / 'rawdata-korean.db').write_bytes(b'SQLite format 3\x00fixture')
        previous = {k: os.environ.get(k) for k in ('VIOLET_EXPORT_ROOT', 'VIOLET_SYNC_STATE')}
        os.environ['VIOLET_EXPORT_ROOT'] = str(export)
        os.environ['VIOLET_SYNC_STATE'] = str(Path(self.temp.name) / 'state')
        try:
            spec = importlib.util.spec_from_file_location('test_download_server', Path(__file__).resolve().parents[1] / 'mobile-db/server.py')
            module = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(module)
        finally:
            for k, v in previous.items():
                if v is None: os.environ.pop(k, None)
                else: os.environ[k] = v
        module.Handler.log_message = lambda *args: None
        httpd = http.server.ThreadingHTTPServer(('127.0.0.1', 0), functools.partial(module.Handler, directory=str(export)))
        threading.Thread(target=httpd.serve_forever, daemon=True).start()
        self.addCleanup(httpd.server_close)
        self.addCleanup(httpd.shutdown)
        base = f'http://127.0.0.1:{httpd.server_port}'
        with urllib.request.urlopen(base + '/rawdata') as response:
            self.assertEqual(response.read(), b'SQLite format 3\x00fixture')
        with urllib.request.urlopen(base + '/syncversion.txt') as response:
            self.assertIn((base + '/rawdata').encode(), response.read())
        req = urllib.request.Request(base + '/api/activity-sync', data=json.dumps({'device': self.app, 'origin': 'app', 'read': [], 'download': []}).encode(), headers={'Content-Type': 'application/json', 'X-Violet-Sync-Token': self.bookmarks.token, 'Origin': 'http://127.0.0.1:3001'})
        with urllib.request.urlopen(req) as response:
            self.assertEqual(json.load(response)['version'], 1)
            self.assertEqual(response.headers['Access-Control-Allow-Origin'], 'http://127.0.0.1:3001')
        with self.assertRaises(urllib.error.HTTPError) as error:
            urllib.request.urlopen(urllib.request.Request(base + '/api/activity-sync', data=b'{}'))
        self.assertEqual(error.exception.code, 401)

if __name__ == '__main__':
    unittest.main()
