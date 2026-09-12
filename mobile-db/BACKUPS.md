# Content server settings and complete app backups

After merging this change into `dev`, update only the Pi mobile service:

```sh
cd ~/violet
curl -fsSL https://raw.githubusercontent.com/pingpingjinping/violet-release/dev/mobile-db/install-server.sh -o /tmp/violet-mobile-server-install.sh
sh /tmp/violet-mobile-server-install.sh
```

This installer preserves the current web frontend, exported databases, backup files and sync token. Source files are saved in `mobile-server-backup-*` before replacement. No additional resident container is introduced.

Build and install the new IPA over the existing app with the same bundle ID. App settings now offer:

- **작품 서버 주소**: editable content server and independent connection checks. Existing Pi defaults to `http://192.168.0.39:3001`; its database endpoint uses port 3002. Custom HTTPS/reverse-proxy deployments must expose `/api/health` on the selected web base and `/syncversion.txt` and `/api/server-info` on the database base. Public CDN database URLs remain supported.
- **앱·웹 기록 동기화**: independent private server (normally `http://PI_IP:3002`) and existing token. Changing the content server does not change this destination.
- **Pi 전체 백업·복원**: manual upload, latest 100 backup versions, and restore. The existing User App ID card's backup button and the older bookmark restore entry open this screen too.

Backups include `fa_userid` (User App ID), bookmark folders/articles/artists, all local read sessions, shared read/download completion metadata, user bookmarks/history and cropped-image bookmark coordinates when present. Completed native downloads are converted to display metadata. Content databases and downloaded files/paths are excluded; restoring never creates a fake locally downloaded file.

Backups are immutable gzip JSON files under `mobile-db/state/backups`, authenticated with the existing sync token. Limits are 16 MiB compressed, 128 MiB expanded and 500,000 app records; oversized input is rejected rather than silently trimmed. Files are retained until removed administratively; the app lists the latest 100. The server validates gzip checksums using bounded streaming buffers, and the app checks SHA-256, schema and folder references before import.

Restore first saves a local `before-restore-*.json.gz` emergency copy in the app Documents directory and uploads the current records as a new Pi backup. If either step fails, SQLite records are untouched. Table replacement is transactional. Download files/items remain local; User App ID is restored and automatic record sync is disabled so that the live shared state cannot immediately overwrite a selected older backup. Re-enable it after checking the restored data. The screen reopens the app's main pages to refresh record caches.

Graph/LLM support indicators are server-advertised configuration, not runtime health checks or newly implemented app features. The Python service advertises them only when `VIOLET_GRAPH_BASE_URL` / `VIOLET_LLM_BASE_URL` is set in its environment.
