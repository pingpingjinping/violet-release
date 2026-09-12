import concurrent.futures
import json
import sqlite3
import sys
import tempfile
import unittest
import uuid
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'mobile-db'))
from bookmark_sync import BookmarkStore

class BookmarkSyncTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.store = BookmarkStore(self.temp.name)

    def tearDown(self):
        self.temp.cleanup()

    def payload(self, revision=0, add=(), remove=()):
        return {'requestId': str(uuid.uuid4()), 'baseRevision': revision,
                'add': list(add), 'remove': list(remove)}

    def test_initial_merge_and_empty_web(self):
        result = self.store.exchange(self.payload(add=['100', '100', '200']))
        self.assertEqual(result['articles'], ['100', '200'])
        self.assertEqual(self.store.exchange(self.payload())['articles'], ['100', '200'])

    def test_deletion_and_stale_client_do_not_resurrect(self):
        first = self.store.exchange(self.payload(add=['100']))
        deleted = self.store.exchange(self.payload(first['revision'], remove=['100']))
        self.assertEqual(deleted['articles'], [])
        stale = self.store.exchange(self.payload(add=['100']))
        self.assertEqual(stale['articles'], [])
        self.assertEqual(stale['conflicts'], 1)
        readded = self.store.exchange(self.payload(deleted['revision'], add=['100']))
        self.assertEqual(readded['articles'], ['100'])

    def test_lost_response_retry_cannot_repeat_deleted_operation(self):
        batch = self.payload(add=['100'])
        first = self.store.exchange(batch)
        self.store.exchange(self.payload(first['revision'], remove=['100']))
        self.assertEqual(self.store.exchange(batch)['articles'], [])

    def test_reused_request_id_with_new_payload_is_rejected(self):
        batch = self.payload(add=['100'])
        self.store.exchange(batch)
        batch['add'] = ['200']
        with self.assertRaises(ValueError): self.store.exchange(batch)

    def test_invalid_payload_is_atomic(self):
        for payload in [self.payload(add=['../token']), self.payload(add=['100'], remove=['100']), self.payload(revision=True)]:
            with self.assertRaises(ValueError): self.store.exchange(payload)
        self.assertEqual(self.store.exchange(self.payload())['articles'], [])

    def test_state_reset_is_not_silently_accepted(self):
        with self.assertRaises(ValueError): self.store.exchange(self.payload(revision=99))

    def test_parallel_clients_merge_without_lost_updates(self):
        with concurrent.futures.ThreadPoolExecutor(max_workers=4) as executor:
            list(executor.map(lambda i: self.store.exchange(self.payload(add=[str(i)])), range(20)))
        self.assertEqual(len(self.store.exchange(self.payload())['articles']), 20)

    def test_restart_retains_token_and_tombstones(self):
        first = self.store.exchange(self.payload(add=['100']))
        self.store.exchange(self.payload(first['revision'], remove=['100']))
        restarted = BookmarkStore(self.temp.name)
        self.assertEqual(restarted.token, self.store.token)
        self.assertEqual(restarted.exchange(self.payload(add=['100']))['articles'], [])

    def test_real_backup_numeric_membership_without_private_fixture(self):
        # Similar scale to the user's 8,050 distinct IDs, without personal data.
        first = self.store.exchange(self.payload(add=[str(i) for i in range(8050)]))
        self.assertEqual(len(first['articles']), 8050)
        size = self.store.path.stat().st_size
        self.assertLess(size, 2 * 1024 * 1024)

if __name__ == '__main__':
    unittest.main()
