import json
import hashlib
import functools
import http.server
import os
import sqlite3
import threading
import time
from urllib.parse import urlparse
from pathlib import Path
from bookmark_sync import BookmarkStore, handle_request
from activity_sync import ActivityStore
from backup_store import BackupStore

ROOT = Path(os.environ.get('VIOLET_EXPORT_ROOT', '/export'))
ROOT.mkdir(parents=True, exist_ok=True)
store = BookmarkStore(os.environ.get('VIOLET_SYNC_STATE', '/state'))
activity_store = ActivityStore(store)
backup_store = BackupStore(store)

def make_snapshot():
    temp = ROOT / 'rawdata-korean.tmp.db'
    for suffix in ('', '-journal', '-wal', '-shm'):
        Path(str(temp) + suffix).unlink(missing_ok=True)
    source = sqlite3.connect('file:/content-data/data.db?mode=ro', uri=True, timeout=60)
    target = sqlite3.connect(temp)
    count = 0
    try:
        source.execute('PRAGMA cache_size=-8192')
        source.execute('BEGIN')
        target.execute('PRAGMA cache_size=-8192')
        schema = source.execute("SELECT sql FROM sqlite_master WHERE type='table' AND name='HitomiColumnModel'").fetchone()
        if not schema:
            raise RuntimeError('Missing content table')
        target.execute(schema[0])
        columns = [row[1] for row in source.execute('PRAGMA table_info("HitomiColumnModel")')]
        names = ', '.join('"' + name.replace('"', '""') + '"' for name in columns)
        placeholders = ', '.join('?' for _ in columns)
        rows = source.execute(f'SELECT {names} FROM HitomiColumnModel WHERE lower(trim(Language)) = ?', ('korean',))
        while True:
            batch = rows.fetchmany(1000)
            if not batch:
                break
            target.executemany(f'INSERT INTO HitomiColumnModel ({names}) VALUES ({placeholders})', batch)
            target.commit()
            count += len(batch)
        if not count:
            raise RuntimeError('No Korean articles found')
        for (sql,) in source.execute("SELECT sql FROM sqlite_master WHERE type='index' AND tbl_name='HitomiColumnModel' AND sql IS NOT NULL"):
            target.execute(sql)
        target.commit()
        if target.execute('PRAGMA quick_check').fetchone()[0] != 'ok':
            raise RuntimeError('Database validation failed')
    finally:
        target.close()
        source.close()
    output = ROOT / 'rawdata-korean.db'
    def digest(path):
        value = hashlib.sha256()
        with path.open('rb') as stream:
            while chunk := stream.read(1024 * 1024):
                value.update(chunk)
        return value.digest()
    if output.exists() and digest(temp) == digest(output):
        temp.unlink()
        print('Korean DB unchanged; keeping snapshot version', flush=True)
        return
    os.replace(temp, output)
    manifest = ROOT / 'syncversion.tmp'
    manifest.write_text(f'db {int(time.time())} http://localhost:3002/rawdata\n', encoding='utf-8')
    os.replace(manifest, ROOT / 'syncversion.txt')
    for name in ('rawdata.db', 'rawdata.tmp.db', 'rawdata.tmp.db-journal', 'rawdata.tmp.db-wal', 'rawdata.tmp.db-shm'):
        (ROOT / name).unlink(missing_ok=True)
    print(f'Korean DB ready: {count:,} articles, {output.stat().st_size / 1048576:.1f} MiB', flush=True)

class Handler(http.server.SimpleHTTPRequestHandler):
    def end_headers(self):
        origin = self.headers.get('Origin', '')
        parsed = urlparse(origin)
        host = urlparse('http://' + self.headers.get('Host', '')).hostname
        if parsed.scheme == 'http' and parsed.hostname == host and parsed.port == 3001:
            self.send_header('Access-Control-Allow-Origin', origin)
            self.send_header('Vary', 'Origin')
        self.send_header('Cache-Control', 'no-store')
        super().end_headers()

    def do_GET(self):
        if self.path == '/api/server-info':
            body = json.dumps({'schema': 1, 'features': {
                'db': True, 'backups': True,
                'graph': bool(os.environ.get('VIOLET_GRAPH_BASE_URL')),
                'llm': bool(os.environ.get('VIOLET_LLM_BASE_URL')),
            }}).encode()
            self.send_response(200)
            self.send_header('Content-Type', 'application/json')
            self.send_header('Content-Length', str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return
        if self.path == '/api/backups' or self.path.startswith('/api/backups/'):
            backup_store.handle(self)
            return
        if self.path == '/rawdata':
            self.path = '/rawdata-korean.db'
        if self.path == '/syncversion.txt':
            output = ROOT / 'rawdata-korean.db'
            if not output.exists():
                self.send_error(503)
                return
            host = self.headers.get('Host', 'localhost:3002')
            body = f'db {int(output.stat().st_mtime)} http://{host}/rawdata\n'.encode()
            self.send_response(200)
            self.send_header('Content-Type', 'text/plain')
            self.send_header('Content-Length', str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return
        super().do_GET()

    def do_OPTIONS(self):
        self.send_response(204)
        self.send_header('Access-Control-Allow-Methods', 'GET, POST, OPTIONS')
        self.send_header('Access-Control-Allow-Headers', 'Content-Type, X-Violet-Sync-Token, X-Violet-User-App-Id')
        self.end_headers()

    def do_POST(self):
        if self.path == '/api/backups':
            backup_store.handle(self)
            return
        if self.path not in ('/api/bookmark-sync', '/api/activity-sync'):
            self.send_error(404)
            return
        self.connection.settimeout(60)
        handle_request(self, activity_store if self.path == '/api/activity-sync' else store)

def refresh_loop():
    while True:
        try:
            make_snapshot()
        except Exception as error:
            print(f'Korean export failed: {error}', flush=True)
        time.sleep(3600)

if __name__ == '__main__':
    threading.Thread(target=refresh_loop, daemon=True).start()
    handler = functools.partial(Handler, directory=str(ROOT))
    server = http.server.ThreadingHTTPServer(('0.0.0.0', 3002), handler)
    print('DB and bookmark sync server listening on port 3002', flush=True)
    server.serve_forever()
