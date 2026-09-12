"""Shared reading progress and completed-download history, without file paths."""
import sqlite3
import uuid

LIMIT = 100000

class ActivityStore:
    def __init__(self, bookmarks):
        self.bookmarks = bookmarks
        self.token = bookmarks.token
        with bookmarks.connect() as db:
            db.execute('''CREATE TABLE IF NOT EXISTS Activity (
                Kind TEXT NOT NULL, Device TEXT NOT NULL, Article TEXT NOT NULL,
                Origin TEXT NOT NULL, Timestamp INTEGER NOT NULL,
                Page INTEGER NOT NULL, Type INTEGER NOT NULL,
                PRIMARY KEY (Kind, Device, Article))''')

    def exchange(self, payload):
        if not isinstance(payload, dict) or payload.get('origin') not in ('app', 'web'):
            raise ValueError('Invalid origin')
        device = payload.get('device')
        try:
            device = str(uuid.UUID(device))
        except (ValueError, TypeError, AttributeError):
            raise ValueError('Invalid device') from None
        entries = []
        for kind in ('read', 'download'):
            rows = payload.get(kind)
            if not isinstance(rows, list) or len(rows) > LIMIT:
                raise ValueError('Invalid activity list')
            for row in rows:
                if not isinstance(row, dict):
                    raise ValueError('Invalid activity')
                article, timestamp = row.get('article'), row.get('timestamp')
                page, read_type = row.get('page', 0), row.get('type', 0)
                if (not isinstance(article, str) or not article.isascii() or
                    not article.isdigit() or len(article) > 20 or
                    type(timestamp) is not int or not 0 < timestamp <= 8640000000000000 or
                    type(page) is not int or not 0 <= page <= 1000000 or
                    type(read_type) is not int or read_type not in (0, 1)):
                    raise ValueError('Invalid activity fields')
                entries.append((kind, device, article, payload['origin'], timestamp,
                                page if kind == 'read' else 0,
                                read_type if kind == 'read' else 0))
        with self.bookmarks.connect() as db:
            db.execute('BEGIN IMMEDIATE')
            db.executemany('''INSERT INTO Activity VALUES (?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(Kind, Device, Article) DO UPDATE SET
                Timestamp=excluded.Timestamp, Page=excluded.Page, Type=excluded.Type
                WHERE excluded.Timestamp > Activity.Timestamp''', entries)
            rows = db.execute('SELECT * FROM Activity ORDER BY Timestamp DESC, Kind, Device, Article').fetchall()
            if len(rows) > LIMIT:
                raise ValueError('Activity limit exceeded')
            return {'version': 1, 'records': [
                {'kind': k, 'device': d, 'article': a, 'origin': o,
                 'timestamp': t, 'page': p, 'type': rt}
                for k, d, a, o, t, p, rt in rows]}
