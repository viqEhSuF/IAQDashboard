#!/bin/bash
# Imports a V1 export (from export_v1.sh) into a V2 system.
#
# Run on the V2 Pi after database/iaq_schema.sql has been applied and the Pi's
# time zone set to the site's, before the stations are reflashed:
#   sudo bash ~/IAQDashboard/migration/import_v1.sh ~/v1_export_YYYYMMDD_HHMM.sql.gz
#
# Loads the export into a separate staging database (v1_import), then copies
# it into the V2 tables with import_v1.sql. Safe to run again: readings already
# imported are skipped, and nothing already in V2 is overwritten.
#
# IGNORE_TZ=1 skips the time zone check. Use it only when the V1 Pi was set to
# the wrong time zone and this one is set to the right one.

set -euo pipefail

EXPORT=${1:-}
HERE=$(cd "$(dirname "$0")" && pwd)

if [ "$(id -u)" -ne 0 ]; then
  echo "Run this with sudo: sudo bash $0 <export file>" >&2
  exit 1
fi
if [ -z "$EXPORT" ] || [ ! -f "$EXPORT" ]; then
  echo "Usage: sudo bash $0 <v1_export_....sql.gz>" >&2
  exit 1
fi

# 1. The V2 schema must be in place
if ! mariadb -N -e "SELECT 1 FROM buildingData.sen55_readings LIMIT 1" >/dev/null 2>&1; then
  echo "The V2 database isn't set up yet. Apply database/iaq_schema.sql first (DEPLOYMENT.md, step 2a)." >&2
  exit 1
fi

# 2. The time zone must match the V1 system's, and MariaDB must be using it
V1_TZ=$(zcat -f "$EXPORT" | head -1 | sed -n 's/^-- v1_timezone: //p' || true)
HERE_TZ=$(timedatectl show -p Timezone --value 2>/dev/null || cat /etc/timezone 2>/dev/null || echo unknown)
if [ "${IGNORE_TZ:-0}" != 1 ] && [ -n "$V1_TZ" ] && [ "$V1_TZ" != unknown ] && [ "$V1_TZ" != "$HERE_TZ" ]; then
  echo "This Pi's time zone is $HERE_TZ, but the V1 system used $V1_TZ." >&2
  echo "Set it to match, restart MariaDB and run this again:" >&2
  echo "  sudo timedatectl set-timezone $V1_TZ && sudo systemctl restart mariadb" >&2
  exit 1
fi
DB_OFFSET=$(mariadb -N -e "SELECT TIMESTAMPDIFF(MINUTE, UTC_TIMESTAMP(), NOW())")
OS_OFFSET=$(date +%z | awk '{ s = substr($0, 1, 1) == "-" ? -1 : 1; print s * (substr($0, 2, 2) * 60 + substr($0, 4, 2)) }')
if [ "$((DB_OFFSET - OS_OFFSET))" -gt 1 ] || [ "$((OS_OFFSET - DB_OFFSET))" -gt 1 ]; then
  echo "MariaDB is still on a different time zone from the system." >&2
  echo "Restart it so it picks up the change, then run this again:" >&2
  echo "  sudo systemctl restart mariadb" >&2
  exit 1
fi

# 3. Load the export into the staging database
echo "Loading $EXPORT into the staging database v1_import..."
mariadb -e "DROP DATABASE IF EXISTS v1_import; CREATE DATABASE v1_import"
zcat -f "$EXPORT" | mariadb v1_import

RECTIME_TYPE=$(mariadb -N -e "SELECT DATA_TYPE FROM information_schema.COLUMNS WHERE TABLE_SCHEMA = 'v1_import' AND TABLE_NAME = 'IAQ_SEN55' AND COLUMN_NAME = 'recTime'")
if [ -z "$RECTIME_TYPE" ]; then
  echo "The export has no IAQ_SEN55 table with a recTime column; it doesn't look like a V1 export." >&2
  exit 1
fi

if [ "${IGNORE_TZ:-0}" = 1 ] && [ "$RECTIME_TYPE" != timestamp ]; then
  echo "This export stores local times ($RECTIME_TYPE), so it must be imported in the V1 time zone ($V1_TZ)." >&2
  exit 1
fi

# 4. On the first run, V2 should hold no readings from V1's time span (from
#    bench testing, for example). Readings from stations already running V2
#    firmware here come after it and are fine.
FIRST_RUN=$(mariadb -N buildingData -e "SELECT COUNT(*) = 0 FROM station_calibration WHERE note LIKE 'V2 readings from the conversion on%'")
V1_LAST=$(mariadb -N -e "SELECT MAX(recTime) FROM v1_import.IAQ_SEN55")
OVERLAP=$(mariadb -N buildingData -e "SELECT COUNT(*) FROM sen55_readings WHERE measured_at <= '$V1_LAST'")
if [ "$FIRST_RUN" = 1 ] && [ "$OVERLAP" -gt 0 ]; then
  echo "This V2 database already has $OVERLAP readings from before the V1 system's last"
  echo "reading ($V1_LAST), probably from testing. They would be mixed into the station"
  echo "history. To clear them first:"
  echo "  sudo mariadb buildingData -e \"DELETE FROM sen55_readings WHERE measured_at <= '$V1_LAST'\""
  read -rp "Continue anyway and keep them? [y/N] " ANSWER || ANSWER=n
  [[ "$ANSWER" =~ ^[Yy] ]] || exit 1
fi

# 5. Copy into the V2 tables
echo "Copying readings and station names into V2..."
mariadb -t < "$HERE/import_v1.sql"

# The dashboard's queries need up-to-date statistics after a bulk load
mariadb buildingData -e "ANALYZE TABLE sen55_readings, stations, station_calibration" >/dev/null

echo
echo "Done. Check the dashboard, then remove the staging copy when you're satisfied:"
echo "  sudo mariadb -e \"DROP DATABASE v1_import\""
