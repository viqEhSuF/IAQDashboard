#!/bin/bash
# Exports a V1 system's readings and station names for conversion to V2.
#
# Run on the V1 Pi (the old SD card), right before switching to V2:
#   sudo bash export_v1.sh
#
# Writes v1_export_<date>_<time>.sql.gz to the home folder of the user who ran
# sudo, and prints the readings per station so the import can be checked
# against them. The V1 database is only read, never changed.

set -euo pipefail

DB=buildingData

if [ "$(id -u)" -ne 0 ]; then
  echo "Run this with sudo: sudo bash $0" >&2
  exit 1
fi

SQL=$(command -v mariadb || command -v mysql || true)
DUMP=$(command -v mariadb-dump || command -v mysqldump || true)
if [ -z "$SQL" ] || [ -z "$DUMP" ]; then
  echo "The MariaDB client tools (mariadb / mariadb-dump) were not found." >&2
  exit 1
fi

# Root normally logs in through the system account; ask for a password if not
if ! "$SQL" -e "SELECT 1" >/dev/null 2>&1; then
  read -rsp "MariaDB root password: " MYSQL_PWD; echo
  export MYSQL_PWD
  if ! "$SQL" -u root -e "SELECT 1" >/dev/null 2>&1; then
    echo "Couldn't log in to MariaDB as root." >&2
    exit 1
  fi
fi

TABLES=$("$SQL" -u root -N "$DB" -e "SHOW TABLES" | grep -xE 'IAQ_SEN55|location_names' | tr '\n' ' ' || true)
TABLES=${TABLES% }
if [[ " $TABLES " != *" IAQ_SEN55 "* ]]; then
  echo "Table IAQ_SEN55 was not found in the $DB database. Is this a V1 system?" >&2
  exit 1
fi

TZ_NAME=$(timedatectl show -p Timezone --value 2>/dev/null || cat /etc/timezone 2>/dev/null || true)
TZ_NAME=${TZ_NAME:-unknown}

OWNER=${SUDO_USER:-root}
OUT_DIR=$(getent passwd "$OWNER" | cut -d: -f6)
OUT="$OUT_DIR/v1_export_$(date +%Y%m%d_%H%M).sql.gz"

echo "Exporting $TABLES from $DB (time zone: $TZ_NAME)..."
# The first line records the time zone, which the import checks.
# --tz-utc writes TIMESTAMP values in UTC, so they load correctly anywhere.
if ! { echo "-- v1_timezone: $TZ_NAME"
       "$DUMP" -u root --single-transaction --tz-utc "$DB" $TABLES
     } | gzip > "$OUT"; then
  rm -f "$OUT"
  echo "The export failed; nothing was saved." >&2
  exit 1
fi
chown "$OWNER" "$OUT"

echo
echo "Readings per station in the export:"
"$SQL" -u root -t "$DB" -e "
  SELECT location AS station, COUNT(*) AS readings,
         MIN(recTime) AS first_reading, MAX(recTime) AS last_reading
  FROM IAQ_SEN55 GROUP BY location ORDER BY location"

if [[ " $TABLES " == *" location_names "* ]]; then
  echo "Station names:"
  "$SQL" -u root -t "$DB" -e "SELECT location AS station, name FROM location_names ORDER BY location"
else
  echo "(No station names table; stations will be unnamed in V2.)"
fi

echo
echo "Saved $OUT ($(du -h "$OUT" | cut -f1))"
echo "Copy it off this Pi before switching cards, for example from your computer:"
echo "  scp $OWNER@$(hostname -I | awk '{print $1}'):$OUT ."
