#!/bin/sh
set -eu

cd "${VIOLET_PROJECT_DIR:-$HOME/violet}"
# Newer installations store history/bookmarks in the backend. Applying this
# browser-storage frontend bundle would remove APIs required by their screens.
if grep -q 'getHistoryEntries' violet-web/packages/frontend/src/pages/HistoryPage.tsx 2>/dev/null; then
    printf '%s\n' 'This newer backend-based frontend needs a version-matched compatibility patch.' >&2
    exit 1
fi
task_backup_dir="$PWD/bookmark-sync-backup-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$task_backup_dir" mobile-db
task_download_dir=$(mktemp -d)
trap 'rm -rf "$task_download_dir"' EXIT

task_ref="${VIOLET_SYNC_REF:-dev}"
task_base="https://raw.githubusercontent.com/pingpingjinping/violet-release/$task_ref"
task_paths='mobile-db/server.py
mobile-db/bookmark_sync.py
mobile-db/activity_sync.py
mobile-db/compose.yml
mobile-db/.gitignore
violet-web/packages/frontend/src/services/user-database.ts
violet-web/packages/frontend/src/services/bookmark-sync.ts
violet-web/packages/frontend/src/components/settings/BookmarkSyncSettings.tsx
violet-web/packages/frontend/src/App.tsx
violet-web/packages/frontend/src/pages/SettingsPage.tsx
violet-web/packages/frontend/src/i18n/locales/en.json
violet-web/packages/frontend/src/i18n/locales/ko.json
violet-web/packages/frontend/src/i18n/locales/ja.json
violet-web/packages/frontend/src/i18n/locales/zh.json
violet-web/packages/frontend/src/services/activity-sync.ts
violet-web/packages/frontend/src/hooks/useSharedActivity.ts
violet-web/packages/frontend/src/pages/HistoryPage.tsx
violet-web/packages/frontend/src/api/downloads.ts
violet-web/packages/frontend/src/hooks/useDownloads.ts
violet-web/packages/frontend/src/components/search/ArticleCard.tsx
violet-web/packages/frontend/src/pages/ArticlePage.tsx
violet-web/packages/frontend/src/pages/DownloadsPage.tsx
violet-web/packages/frontend/src/pages/ViewerPage.tsx'

# Complete all downloads before changing the running installation.
printf '%s\n' "$task_paths" | while IFS= read -r task_path; do
    mkdir -p "$task_download_dir/$(dirname "$task_path")"
    curl -fsSL "$task_base/$task_path" -o "$task_download_dir/$task_path"
done

docker compose -p violet-mobile -f mobile-db/compose.yml stop

printf '%s\n' "$task_paths" | while IFS= read -r task_path; do
    mkdir -p "$(dirname "$task_path")"
    if [ -f "$task_path" ]; then
        mkdir -p "$task_backup_dir/$(dirname "$task_path")"
        cp "$task_path" "$task_backup_dir/$task_path"
    fi
    cp "$task_download_dir/$task_path" "$task_path"
done

docker compose -p violet-mobile -f mobile-db/compose.yml up -d
docker compose build web
docker compose up -d --no-deps web

printf '\nBackup directory: %s\n' "$task_backup_dir"
printf 'Sync token (enter the same value in app and web):\n'
docker compose -p violet-mobile -f mobile-db/compose.yml exec -T db-download cat /state/sync-token.txt
printf '\n'
