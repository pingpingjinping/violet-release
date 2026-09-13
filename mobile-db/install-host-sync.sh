#!/bin/sh
set -eu

cd "${VIOLET_PROJECT_DIR:-$HOME/violet}"
task_ref="${VIOLET_HOST_SYNC_REF:-dev}"
task_base="https://raw.githubusercontent.com/pingpingjinping/violet-release/$task_ref"
task_download_dir=$(mktemp -d)
trap 'rm -rf "$task_download_dir"' EXIT
task_backup_dir="$PWD/host-sync-backup-$(date +%Y%m%d-%H%M%S)"

task_paths='mobile-db/server.py
mobile-db/host-sync.override.yml
violet-web/packages/backend/src/services/sync-manager.ts
violet-web/packages/frontend/src/api/sync.ts
violet-web/packages/frontend/src/pages/SettingsPage.tsx
violet-web/packages/frontend/src/i18n/locales/en.json
violet-web/packages/frontend/src/i18n/locales/ko.json
violet-web/packages/frontend/src/i18n/locales/ja.json
violet-web/packages/frontend/src/i18n/locales/zh.json
violet-web/packages/frontend/src/i18n/locales/eo.json
violet-web/packages/frontend/src/i18n/locales/it.json
violet-web/packages/frontend/src/i18n/locales/pt.json'

printf '%s\n' "$task_paths" | while IFS= read -r task_path; do
    mkdir -p "$task_download_dir/$(dirname "$task_path")"
    curl -fsSL "$task_base/$task_path" -o "$task_download_dir/$task_path"
done

if [ -f docker-compose.override.yml ] &&
   ! grep -q 'Managed by mobile-db/install-host-sync.sh' docker-compose.override.yml; then
    printf '%s\n' 'docker-compose.override.yml already exists and is not managed by this installer.' >&2
    printf '%s\n' 'Move or merge that file first; nothing was changed.' >&2
    exit 1
fi

mkdir -p "$task_backup_dir"
printf '%s\n' "$task_paths" | while IFS= read -r task_path; do
    task_target="$task_path"
    if [ "$task_path" = 'mobile-db/host-sync.override.yml' ]; then
        task_target='docker-compose.override.yml'
    fi
    if [ -f "$task_target" ]; then
        mkdir -p "$task_backup_dir/$(dirname "$task_target")"
        cp "$task_target" "$task_backup_dir/$task_target"
    fi
done

docker compose -p violet-mobile -f mobile-db/compose.yml stop

printf '%s\n' "$task_paths" | while IFS= read -r task_path; do
    task_target="$task_path"
    if [ "$task_path" = 'mobile-db/host-sync.override.yml' ]; then
        task_target='docker-compose.override.yml'
    fi
    mkdir -p "$(dirname "$task_target")"
    cp "$task_download_dir/$task_path" "$task_target"
done

docker compose -p violet-mobile -f mobile-db/compose.yml up -d --force-recreate
docker compose build web
docker compose up -d --force-recreate hsync
docker compose up -d --no-deps web

printf '\nPi database sync installed. Backup: %s\n' "$task_backup_dir"
printf '%s\n' 'Refresh the web settings page, then press Sync now.'
