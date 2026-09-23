#!/usr/bin/env bash
# rocketchat-restore-database.sh [backup-file-name]
#
# Replaces the Rocket.Chat database with one of the archives the backups service wrote.
#
#   ./rocketchat-restore-database.sh               list and ask
#   ./rocketchat-restore-database.sh <file-name>   restore that one
#
# EVERY PATH, NAME AND CREDENTIAL COMES FROM THE RUNNING BACKUPS CONTAINER.
# The previous version restored with mongorestore --drop, which replaces only
# the collections the archive holds: a collection created after the backup
# survived the restore, and the test worked around that rather than catch it.
# It also carried the backup directory as a literal and found its containers
# by a name filter that misses them under any -p but the default.
# The backup loop reads its own environment, so this reads the same one, and
# the two cannot disagree.
#
# CI runs this exact file against a marker written after the backup it
# restores, and requires the marker to be gone.
#
# Set COMPOSE_PROJECT_NAME if the stack was started with a -p other than rocketchat.
set -Eeuo pipefail

PROJECT="${COMPOSE_PROJECT_NAME:-rocketchat}"
APP_SERVICE="rocketchat"

cid() {  # the container of one compose service in this project
  docker ps -aq --filter "label=com.docker.compose.project=$PROJECT" \
    --filter "label=com.docker.compose.service=$1" | head -n 1
}
APP="$(cid "$APP_SERVICE")"; BKP="$(cid backups)"
[ -n "$BKP" ] || { echo "error: no backups container in compose project '$PROJECT' (set COMPOSE_PROJECT_NAME)" >&2; exit 1; }
[ -n "$APP" ] || { echo "error: no $APP_SERVICE container in compose project '$PROJECT'" >&2; exit 1; }
[ "$(docker inspect -f '{{.State.Running}}' "$BKP")" = true ] || { echo "error: the backups container is not running" >&2; exit 1; }

env_of() { docker exec "$BKP" printenv "$1"; }
DIR="$(env_of DATA_BACKUPS_PATH)"; NAME="$(env_of DATA_BACKUP_NAME)"

SELECTED="${1:-}"
if [ -z "$SELECTED" ]; then
  echo "Database backups in $DIR:"
  docker exec "$BKP" sh -c "ls -1 '$DIR' | grep -E '^$NAME-.*\\.archive\\.gz\$'" || { echo "  none found" >&2; exit 1; }
  read -r -p "File name to restore: " SELECTED
fi
case "$SELECTED" in ""|*/*) echo "error: give a file name from the list, not a path" >&2; exit 1 ;; esac
docker exec "$BKP" gunzip -t "$DIR/$SELECTED" >/dev/null \
  || { echo "error: $DIR/$SELECTED is missing or does not open; nothing was changed" >&2; exit 1; }

echo "Stopping $APP_SERVICE so nothing writes while the database is replaced"
docker stop "$APP" >/dev/null
restart() { docker start "$APP" >/dev/null && echo "Started $APP_SERVICE"; }
trap 'restart' EXIT
echo "Restoring $SELECTED"
# The whole database goes first, so nothing created after the backup survives;
# mongodump wrote this archive from the database named rocketchat.
if ! docker exec "$BKP" sh -c "set -eu
    mongosh --quiet --host mongodb rocketchat --eval 'db.dropDatabase()' > /dev/null
    mongorestore --quiet -h mongodb:27017 --db rocketchat --gzip --archive='$DIR/$SELECTED'"; then
  echo "error: the restore failed part-way. The database may now be empty: restore another backup before using Rocket.Chat." >&2
  exit 1
fi
echo "Restored $SELECTED into rocketchat"
