"""Authenticated client metadata repair; fill only missing fields of known rows."""
import re
import sqlite3

TOKEN = re.compile(r"[0-9a-fA-F]{10}")


def missing(value):
    return value is None or value.strip().replace("|", "").upper() in ("", "N/A", "NA")


def pipe(values):
    if not isinstance(values, list) or len(values) > 100:
        raise ValueError("invalid tags")
    result = []
    for v in values:
        if (not isinstance(v, str) or not v or len(v) > 200 or v.strip() != v
                or v.lower() in ("n/a", "na") or "|" in v
                or any(ord(c) < 32 for c in v)):
            raise ValueError("invalid tag")
        if v not in result:
            result.append(v)
    return "|" + "|".join(result) + "|" if result else None


def validate(item):
    if not isinstance(item, dict):
        raise ValueError("invalid item")
    gid, pages = item.get("id"), item.get("pages")
    source, token = item.get("source"), item.get("token")
    if (type(gid) is not int or not 0 < gid < 2**63
            or type(pages) is not int or not 0 < pages < 100000):
        raise ValueError("invalid identity")
    if source == "eh":
        if not isinstance(token, str) or not TOKEN.fullmatch(token):
            raise ValueError("invalid token")
    elif source != "hitomi" or token is not None:
        raise ValueError("invalid source")
    a, g = pipe(item.get("artists", [])), pipe(item.get("groups", []))
    if not (a or g):
        raise ValueError("empty repair")
    return gid, pages, source, token, a, g


def apply_repairs(db, items):
    if not isinstance(items, list) or not 1 <= len(items) <= 100:
        raise ValueError("invalid batch")
    rows = [validate(item) for item in items]
    result = []
    db.execute("BEGIN IMMEDIATE")
    try:
        has_fts = db.execute("SELECT 1 FROM sqlite_master WHERE name='FtsTags' AND type='table'").fetchone()
        if not has_fts:
            raise RuntimeError("search index missing")
        for gid, pages, source, token, a, g in rows:
            row = db.execute("""
                SELECT Artists, "Groups", EHash, ExistOnHitomi, Tags
                FROM HitomiColumnModel
                WHERE Id=? AND Files=? AND LOWER(TRIM(Language))='korean'
            """, (gid, pages)).fetchone()
            if row is None or (source == "hitomi" and row[3] != 1) or (source == "eh" and row[2] != token):
                result.append("identity_changed")
                continue
            old_a, old_g, _, hitomi, tags = row
            new_a = a if a and missing(old_a) else old_a
            new_g = g if g and missing(old_g) else old_g
            if new_a == old_a and new_g == old_g:
                result.append("unchanged")
                continue
            db.execute('UPDATE HitomiColumnModel SET Artists=?, "Groups"=? WHERE Id=?',
                       (new_a, new_g, gid))
            if hitomi == 1 or "|expunged|" in (tags or ""):
                db.execute("DELETE FROM FtsTags WHERE rowid=?", (gid,))
                db.execute("""
                    INSERT INTO FtsTags(rowid, Tags, Artists, Groups_, Series, Characters)
                    SELECT Id,
                        TRIM(REPLACE(REPLACE(COALESCE(Tags,''),' ','_'),'|',' ')),
                        TRIM(REPLACE(REPLACE(COALESCE(Artists,''),' ','_'),'|',' ')),
                        TRIM(REPLACE(REPLACE(COALESCE("Groups",''),' ','_'),'|',' ')),
                        TRIM(REPLACE(REPLACE(COALESCE(Series,''),' ','_'),'|',' ')),
                        TRIM(REPLACE(REPLACE(COALESCE(Characters,''),' ','_'),'|',' '))
                    FROM HitomiColumnModel WHERE Id=?
                """, (gid,))
            result.append("applied")
        db.commit()
    except BaseException:
        db.rollback()
        raise
    return result


def handle_metadata_repair(handler, store):
    import secrets
    import json
    from pathlib import Path
    if not secrets.compare_digest(handler.headers.get("X-Violet-Sync-Token", ""), store.token):
        handler.send_error(401)
        return
    try:
        length = int(handler.headers.get("Content-Length", "0"))
        if not 0 < length <= 256 * 1024:
            raise ValueError("invalid body length")
        payload = json.loads(handler.rfile.read(length))
        if not isinstance(payload, dict) or payload.get("schema") != 1:
            raise ValueError("invalid schema")
        state = Path('/content-data/.violet-hsync-state')
        if state.exists() and state.read_text().strip() == 'running':
            handler.send_error(503, 'Collector busy; retry next launch')
            return
        db = sqlite3.connect("file:/content-data/data.db?mode=rw", uri=True, timeout=10)
        try:
            result = apply_repairs(db, payload.get("items"))
        finally:
            db.close()
    except (ValueError, TypeError, UnicodeError):
        handler.send_error(400)
        return
    except (sqlite3.Error, RuntimeError, OSError):
        handler.send_error(503)
        return
    body = json.dumps({"schema": 1, "results": result}).encode()
    handler.send_response(200)
    handler.send_header("Content-Type", "application/json")
    handler.send_header("Content-Length", str(len(body)))
    handler.end_headers()
    handler.wfile.write(body)
