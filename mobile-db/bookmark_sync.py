"""Revision-based bookmark membership sync; user data never lives in /export."""
import json
import secrets
import sqlite3
import uuid
from pathlib import Path

MAX_ITEMS = 100000

class BookmarkStore:
    def __init__(self, root):
        root = Path(root)
        root.mkdir(parents=True, exist_ok=True)
        self.path = root / "bookmarks.sqlite"
        self.token_path = root / "sync-token.txt"
        if not self.token_path.exists():
            with self.token_path.open("x") as token_file:
                token_file.write(secrets.token_urlsafe(32))
            self.token_path.chmod(0o600)
        self.token = self.token_path.read_text().strip()
        with self.connect() as db:
            db.executescript('''
                CREATE TABLE IF NOT EXISTS Meta (Id INTEGER PRIMARY KEY, Revision INTEGER);
                INSERT OR IGNORE INTO Meta VALUES (1, 0);
                CREATE TABLE IF NOT EXISTS Bookmark (
                    Article TEXT PRIMARY KEY, Present INTEGER NOT NULL,
                    Revision INTEGER NOT NULL);
                CREATE TABLE IF NOT EXISTS Receipt (
                    RequestId TEXT PRIMARY KEY, Payload TEXT NOT NULL);
            ''')

    def connect(self):
        db = sqlite3.connect(self.path, timeout=30)
        db.execute("PRAGMA cache_size=-2048")
        return db

    def exchange(self, payload):
        if not isinstance(payload, dict):
            raise ValueError("Invalid payload")
        revision = payload.get("baseRevision")
        request_id = payload.get("requestId")
        if type(revision) is not int or revision < 0:
            raise ValueError("Invalid baseRevision")
        try:
            uuid.UUID(request_id)
        except (ValueError, TypeError, AttributeError):
            raise ValueError("Invalid requestId") from None
        operations = []
        for name in ("add", "remove"):
            items = payload.get(name)
            if not isinstance(items, list) or len(items) > MAX_ITEMS:
                raise ValueError("Invalid bookmark list")
            if any(not isinstance(x, str) or not x.isascii() or not x.isdigit()
                   or len(x) > 20 for x in items):
                raise ValueError("Invalid article ID")
            operations.append(set(items))
        if operations[0] & operations[1]:
            raise ValueError("Overlapping operations")
        serialized = json.dumps(payload, sort_keys=True, separators=(",", ":"))
        with self.connect() as db:
            db.execute("BEGIN IMMEDIATE")
            current = db.execute("SELECT Revision FROM Meta WHERE Id=1").fetchone()[0]
            if revision > current:
                raise ValueError("Server state has been reset; reconnect after backing up")
            receipt = db.execute("SELECT Payload FROM Receipt WHERE RequestId=?", (request_id,)).fetchone()
            if receipt and receipt[0] != serialized:
                raise ValueError("Request ID reused with different data")
            conflicts = 0
            if not receipt:
                for present, items in ((1, operations[0]), (0, operations[1])):
                    for article in sorted(items):
                        row = db.execute("SELECT Present, Revision FROM Bookmark WHERE Article=?", (article,)).fetchone()
                        if row and row[0] == present:
                            continue
                        # A stale device cannot undo another device's newer change.
                        if row and row[1] > revision:
                            conflicts += 1
                            continue
                        current += 1
                        db.execute("INSERT INTO Bookmark VALUES (?, ?, ?) ON CONFLICT(Article) DO UPDATE SET Present=excluded.Present, Revision=excluded.Revision", (article, present, current))
                db.execute("UPDATE Meta SET Revision=? WHERE Id=1", (current,))
                db.execute("INSERT INTO Receipt VALUES (?, ?)", (request_id, serialized))
            articles = [row[0] for row in db.execute("SELECT Article FROM Bookmark WHERE Present=1 ORDER BY Article")]
            if len(articles) > MAX_ITEMS:
                raise ValueError("Bookmark limit exceeded")
            return {"revision": current, "articles": articles, "conflicts": conflicts}

def handle_request(handler, store):
    if not secrets.compare_digest(handler.headers.get("X-Violet-Sync-Token", ""), store.token):
        handler.send_error(401, "Invalid sync token")
        return
    try:
        length = int(handler.headers.get("Content-Length", "0"))
        if not 0 < length <= 8 * 1024 * 1024:
            raise ValueError("Invalid request size")
        payload = json.loads(handler.rfile.read(length))
        result = store.exchange(payload)
    except (ValueError, json.JSONDecodeError):
        handler.send_error(400, "Invalid sync request")
        return
    body = json.dumps(result).encode()
    handler.send_response(200)
    handler.send_header("Content-Type", "application/json")
    handler.send_header("Content-Length", str(len(body)))
    handler.end_headers()
    handler.wfile.write(body)
