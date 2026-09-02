#!/bin/bash

# # rocketchat-restore-database.sh Description
# This script facilitates the restoration of a database backup.
# 1. **Identify Containers**: It first identifies the service and backups containers by name, finding the appropriate container IDs.
# 2. **List Backups**: Displays all available database backups located at the specified backup path.
# 3. **Select Backup**: Prompts the user to copy and paste the desired backup name from the list to restore the database.
# 4. **Stop Service**: Temporarily stops the service to ensure data consistency during restoration.
# 5. **Restore Database**: Restores the `rocketchat` database from the selected gzip-compressed mongodump archive, dropping the current collections first.
# 6. **Start Service**: Restarts the service after the restoration is completed.
# To make the `rocketchat-restore-database.sh` script executable, run the following command:
# `chmod +x rocketchat-restore-database.sh`
# Usage of this script ensures a controlled and guided process to restore the database from an existing backup.

ROCKETCHAT_CONTAINER="$(docker ps -aqf "name=rocketchat-rocketchat")"
ROCKETCHAT_BACKUPS_CONTAINER="$(docker ps -aqf "name=rocketchat-backups")"
BACKUP_PATH="/srv/rocketchat-mongodb/backups/"

echo "--> All available database backups:"

for entry in $(docker container exec "$ROCKETCHAT_BACKUPS_CONTAINER" sh -c "ls $BACKUP_PATH")
do
  echo "$entry"
done

echo "--> Copy and paste the backup name from the list above to restore database and press [ENTER]
--> Example: rocketchat-mongodb-backup-YYYY-MM-DD_hh-mm.archive.gz"
echo -n "--> "

read -r SELECTED_DATABASE_BACKUP

echo "--> $SELECTED_DATABASE_BACKUP was selected"

echo "--> Stopping service..."
docker stop "$ROCKETCHAT_CONTAINER"

echo "--> Restoring database..."
docker exec "$ROCKETCHAT_BACKUPS_CONTAINER" sh -c "mongorestore -h mongodb:27017 --db rocketchat --drop --gzip --archive=${BACKUP_PATH}${SELECTED_DATABASE_BACKUP}"
echo "--> Database recovery completed..."

echo "--> Starting service..."
docker start "$ROCKETCHAT_CONTAINER"
