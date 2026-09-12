# App/web bookmarks, reading progress and download records

App and web exchange article bookmark additions/deletions, the latest reading
position per work/device, and completed-download history. Files, local paths,
failed/pending downloads, artist bookmarks and bookmark folders are not transferred.
Remote bookmarks enter the default folder; existing duplicate rows/folders remain.

Downloads carry only the numeric work ID, timestamp and device/app-or-web origin.
Shared download records appear in the web downloads page and in the app's separate
shared-records page, accessible from Downloads and Sync settings. Work cards show
where a work was downloaded. Downloading again prompts for confirmation. Actual
local download records/files remain separate: a remote completion is never treated
as a local file or a job that can be opened, retried or deleted.

The registry records that a work **was downloaded**. Deleting files or local history
does not remove the shared historical mark. This version does not offer shared
history deletion. Reading sync stores the latest position per work/device, rather
than every session. Local sessions remain intact. When choosing reading position,
the most recent timestamp wins; this allows rereading earlier pages. Devices should
have correct clocks. The wire protocol uses UTC milliseconds and zero-based pages;
Flutter's native one-based saved page is converted in both directions.

## Install

Merge the change into dev first. On the Pi:

```sh
cd ~/violet
curl -fsSL https://raw.githubusercontent.com/pingpingjinping/violet-release/dev/mobile-db/install.sh -o /tmp/violet-bookmark-sync-install.sh
sh /tmp/violet-bookmark-sync-install.sh
```

The installer downloads source first, backs up replaced files, updates the existing
Python server and rebuilds web. It prints the existing shared token. No user.db is
copied or overwritten. The content database, hsync and graph profile remain in place.
The same Python container retains its 128 MiB memory limit. Persistent state lives
in mobile-db/state outside the public export folder. Keep this folder: it stores
the token, bookmark revisions, deletion tombstones and shared records.

Build the updated iOS IPA using the existing workflow and install over the existing
app with the same signing identity. Keep the exported user.db backup. Do not
uninstall the app. Open Settings → 앱·웹 기록 동기화, enter
http://YOUR_PI_HOST:3002 and the token, select daily/weekly and press 지금 동기화.
Then reload the web app at http://YOUR_PI_HOST:3001, enter the same token in Sync
settings and press Sync now. Close/reload old web tabs for the IndexedDB upgrade.
Sync the app first to seed its existing records, then the web.

Automatic exchanges occur on launch/foreground after one or seven days since the
last successful exchange. Sync now bypasses the interval. This is not continuous
or exact-time iOS background scheduling. Badges are current as of the last sync;
unsynchronized/offline changes on another device cannot be detected. A device
kept open all day can use Sync now. Failures preserve all local data and the
previous shared cache, and failed activity exchanges remain due for retry.

## Storage and consistency

Bookmark requests use persistent UUID receipts, revisions and tombstones. Empty
clients pull existing bookmarks rather than deleting them. A stale conflicting
operation cannot override a newer server change. Local bookmark edits made during
an exchange remain pending.

Activity requests are naturally idempotent: kind/device/work is a unique key and
older snapshots cannot replace a newer timestamp. Each device uploads only its
own native reading sessions and completed download jobs. Received records live
in a separate SQLite/IndexedDB cache, preventing echo uploads and fake local files.
Cache replacement is transactional and never overwrites local in-flight edits.

The API uses a shared local token over LAN HTTP, like the existing DB server.
Do not expose it publicly. No private database, token, work-ID list or concrete
LAN address is committed to GitHub. The server derives the DB manifest URL from
the requested host; web CORS allows the same hostname at port 3001.

## Validation

```sh
python -m unittest discover -s tests -p 'test_*sync.py' -v
```

The checks workflow runs server integration tests, builds web, exercises the real
web sync services against fake IndexedDB and mocked HTTP, and analyzes changed
Flutter files. Web tests cover completed-only uploads, remote-only history/download
IDs, separation from real local jobs, due intervals, offline retry and edits during
an exchange. Device checks are still necessary: app-first import, web pull,
bidirectional read progress, both download origins, duplicate confirmation,
offline edits, and iPhone upgrade with existing data.
