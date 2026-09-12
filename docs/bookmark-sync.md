# App/web article bookmark synchronization

This first version synchronizes the presence or absence of numeric article
bookmarks. It preserves existing app folders and duplicate rows. Remote-only
articles go into the default folder. Folder changes, artist bookmarks, reading
history, crop bookmarks, downloaded images and download jobs are not synchronized.
No personal database, bookmark ID list or token is committed to the repository.

The app and web keep their own databases. When enabled, each client exchanges
changes on launch/foreground after one or seven days since its last successful
sync. "Sync now" bypasses that interval. Failures keep local changes pending.
There is no background iOS scheduling or constant polling. A device that remains
open all day can use the manual button.

## Install on WalnutPi

The existing content database download server and its export remain in place.
This adds the bookmark API to the same Python container with the same 128 MiB
memory limit. User state lives in `mobile-db/state`, outside the public `/export`
directory. Do not delete the state directory: it contains the token, revision
history and deletion tombstones.

```sh
cd ~/violet
curl -fsSL https://raw.githubusercontent.com/pingpingjinping/violet-release/codex/bookmark-sync/mobile-db/install.sh -o /tmp/violet-bookmark-sync-install.sh
sh /tmp/violet-bookmark-sync-install.sh
```

The installer downloads all files first, backs up existing source files, updates
the Python server, rebuilds the web image, and prints the shared token. This
does not copy or overwrite either user.db. It requires Internet access on the
WalnutPi for GitHub downloads and Docker builds. The original Docker Compose
configuration, hsync and graph profile are preserved. It does not restart hsync.

## App installation

Merge the change into the fork's dev branch and run its Build iOS IPA workflow.
Install the IPA over the existing app using the same bundle ID/signing account.
Keep the exported user.db backup; do not uninstall the app to install the update.
On the app's settings page choose "앱·웹 작품 북마크 동기화", enter the token,
select the interval, and press "지금 동기화" once. This seeds the server from
the app's existing bookmarks.

## Web setup

Open http://YOUR_PI_HOST:3001/settings in the usual browser, reload the updated
web app, enter the same token in the bookmark sync section, and press Sync now.
Use this exact LAN origin for the Python server's CORS configuration. The token
is kept on the device and is never built into the IPA or JavaScript bundle.
The API uses LAN HTTP, like the existing content download server; HTTPS setup
is outside this change.

## Conflict and retry behavior

Each client stores a last acknowledged bookmark set and server revision.
Only changes relative to that set are sent, so an empty web browser does not
delete the initial app data. The server retains tombstones, and a stale client
cannot override a change made after its acknowledged revision. When a stale
operation conflicts, the newer server change wins. A fresh acknowledged client
can intentionally add a deleted bookmark again.

Requests have persistent UUIDs and receipts. A lost response can be retried
without applying the same operation again. Each client's bookmark update and
new checkpoint commit atomically in its local database. Local edits made during
the network request remain local and are sent on the next sync. Server resets
are rejected instead of silently applying old checkpoints to a new empty DB.

## Validation

```sh
python -m unittest discover -s tests -p test_bookmark_sync.py -v
```

The Bookmark sync checks workflow also builds violet-web and analyzes the two
new Flutter files. Verify on devices: initial app upload, empty web pull, add
on web and pull on app, delete on app and pull on web, offline edits, and retry.
Automatic checks do not replace an actual iPhone installation test.

In the app sync settings, enter http://YOUR_PI_HOST:3002 as the server address.
