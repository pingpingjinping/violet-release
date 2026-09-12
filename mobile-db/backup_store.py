"""Authenticated, immutable gzip backups; validation uses bounded streaming RAM."""
import gzip
import hashlib
import json
import os
from pathlib import Path
import re
import secrets
import threading
import time
import uuid

MAX_UPLOAD = 16 * 1024 * 1024
MAX_RAW = 128 * 1024 * 1024

class BackupStore:
    def __init__(self, sync_store):
        self.store = sync_store
        self.root = sync_store.path.parent / 'backups'
        self.root.mkdir(exist_ok=True)
        self.lock = threading.Lock()
        with self.store.connect() as db:
            db.execute('CREATE TABLE IF NOT EXISTS Backup (Id TEXT PRIMARY KEY, UserId TEXT, Created INTEGER, Size INTEGER, RawSize INTEGER, Digest TEXT)')

    def save(self, stream, size, user):
        if not 0 < size <= MAX_UPLOAD:
            raise ValueError('Backup exceeds 16 MiB compressed limit')
        if not re.fullmatch(r'[\x21-\x7e]{1,256}', user):
            raise ValueError('Invalid User App ID')
        with self.lock:
            ident = str(uuid.uuid4())
            temporary = self.root / (ident + '.tmp')
            output = self.root / (ident + '.json.gz')
            try:
                remaining = size
                digest = hashlib.sha256()
                with temporary.open('xb') as file:
                    while remaining:
                        chunk = stream.read(min(65536, remaining))
                        if not chunk:
                            raise ValueError('Incomplete backup upload')
                        file.write(chunk)
                        digest.update(chunk)
                        remaining -= len(chunk)
                raw_size = 0
                with gzip.open(temporary, 'rb') as file:
                    while chunk := file.read(65536):
                        raw_size += len(chunk)
                        if raw_size > MAX_RAW:
                            raise ValueError('Backup exceeds 128 MiB expanded limit')
                if raw_size == 0:
                    raise ValueError('Empty backup')
                temporary.chmod(0o600)
                os.replace(temporary, output)
                created = int(time.time())
                with self.store.connect() as db:
                    db.execute('INSERT INTO Backup VALUES (?, ?, ?, ?, ?, ?)',
                               (ident, user, created, size, raw_size, digest.hexdigest()))
                return self.get(ident)
            except Exception:
                temporary.unlink(missing_ok=True)
                output.unlink(missing_ok=True)
                raise

    def get(self, ident):
        if str(uuid.UUID(ident)) != ident:
            raise ValueError('Invalid backup ID')
        with self.store.connect() as db:
            row = db.execute('SELECT * FROM Backup WHERE Id=?', (ident,)).fetchone()
        if row is None:
            raise FileNotFoundError('Backup not found')
        return dict(zip(('id', 'userAppId', 'createdAt', 'size', 'rawSize', 'sha256'), row))

    def listing(self):
        with self.store.connect() as db:
            rows = db.execute('SELECT * FROM Backup ORDER BY Created DESC, rowid DESC LIMIT 100').fetchall()
        return [dict(zip(('id', 'userAppId', 'createdAt', 'size', 'rawSize', 'sha256'), r)) for r in rows]

    def handle(self, handler):
        if not secrets.compare_digest(handler.headers.get('X-Violet-Sync-Token', ''), self.store.token):
            handler.send_error(401, 'Invalid sync token')
            return
        try:
            handler.connection.settimeout(60)
            if handler.command == 'POST' and handler.path == '/api/backups':
                result = self.save(handler.rfile, int(handler.headers.get('Content-Length', '0')),
                                   handler.headers.get('X-Violet-User-App-Id', ''))
            elif handler.command == 'GET' and handler.path == '/api/backups':
                result = {'backups': self.listing()}
            elif handler.command == 'GET' and handler.path.startswith('/api/backups/'):
                ident = handler.path.removeprefix('/api/backups/')
                meta = self.get(ident)
                with (self.root / (ident + '.json.gz')).open('rb') as file:
                    handler.send_response(200)
                    handler.send_header('Content-Type', 'application/gzip')
                    handler.send_header('Content-Length', str(meta['size']))
                    handler.send_header('X-Violet-Backup-SHA256', meta['sha256'])
                    handler.end_headers()
                    while chunk := file.read(65536):
                        handler.wfile.write(chunk)
                return
            else:
                handler.send_error(404)
                return
        except FileNotFoundError:
            handler.send_error(404, 'Backup not found')
            return
        except (ValueError, EOFError, gzip.BadGzipFile):
            handler.send_error(400, 'Invalid or oversized gzip backup')
            return
        body = json.dumps(result).encode()
        handler.send_response(200)
        handler.send_header('Content-Type', 'application/json')
        handler.send_header('Content-Length', str(len(body)))
        handler.end_headers()
        handler.wfile.write(body)
