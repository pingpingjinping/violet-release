#!/bin/sh
set -eu
cd "${VIOLET_PROJECT_DIR:-$HOME/violet}"
task_ref="${VIOLET_SERVER_REF:-dev}"
task_root="https://raw.githubusercontent.com/pingpingjinping/violet-release/$task_ref/mobile-db"
task_download_dir=$(mktemp -d)
trap 'rm -rf "$task_download_dir"' EXIT
task_backup_dir="$PWD/mobile-server-backup-$(date +%Y%m%d-%H%M%S)"
for task_name in server.py bookmark_sync.py activity_sync.py backup_store.py compose.yml; do
    curl -fsSL "$task_root/$task_name" -o "$task_download_dir/$task_name"
done
mkdir -p "$task_backup_dir" mobile-db
for task_name in server.py bookmark_sync.py activity_sync.py backup_store.py compose.yml; do
    if [ -f "mobile-db/$task_name" ]; then
        cp "mobile-db/$task_name" "$task_backup_dir/$task_name"
    fi
done
docker compose -p violet-mobile -f mobile-db/compose.yml stop
for task_name in server.py bookmark_sync.py activity_sync.py backup_store.py compose.yml; do
    cp "$task_download_dir/$task_name" "mobile-db/$task_name"
done
docker compose -p violet-mobile -f mobile-db/compose.yml up -d
printf 'Mobile server updated. Source backup: %s\n' "$task_backup_dir"
printf '%s\n' 'Use the existing sync token in App/Web sync settings.'
