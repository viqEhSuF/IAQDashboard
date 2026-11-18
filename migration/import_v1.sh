#!/bin/bash
# Imports a V1 export (from export_v1.sh) into a V2 system.
#
# Run on the V2 Pi after database/iaq_schema.sql has been applied and the Pi's
# time zone set to the site's. Stations can be reflashed before or after; each
# station's conversion time is one second after its own last V1 reading.
#   sudo bash ~/IAQDashboard/migration/import_v1.sh ~/v1_export_YYYYMMDD_HHMM.sql.gz
#
# Loads the export into a separate staging database (v1_import), then copies
# it into the V2 tables with import_v1.sql. Safe to run again: readings already
# imported are skipped, and nothing already in V2 is overwritten.
#
# Settings, given after sudo (for example sudo V1_RH_UNSCALE=1.116 bash ...):
#   V1_TEMP_SCALE  the V1 sketch's tempScale, if not 1.034
#   V1_RH_UNSCALE  the V1 rHscale (1.116) to divide V1's humidity scaling out
#                  of the history; leave it out to keep humidity as V1 recorded it
#   REPLACE_HISTORY=1  delete what V2 holds for each station up to its last V1
#                  reading (an earlier import, or test readings), then import.
#                  Use it to redo the history with a different V1_RH_UNSCALE.
#   IGNORE_TZ=1    skip the time zone check. Use it only when the V1 Pi was set
#                  to the wrong time zone and this one is set to the right one.

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
for SETTING in V1_TEMP_SCALE V1_RH_UNSCALE; do
  if [ -n "${!SETTING:-}" ] && ! { [[ "${!SETTING}" =~ ^[0-9]+(\.[0-9]+)?$ ]] &&
       awk -v v="${!SETTING}" 'BEGIN { exit !(v >= 0.5 && v <= 2) }'; }; then
    echo "$SETTING must be a scale factor between 0.5 and 2, like 1.116 (got '${!SETTING}')." >&2
    exit 1
  fi
done

if [ -n "${REPLACE_HISTORY:-}" ] && [ "$REPLACE_HISTORY" != 1 ]; then
  echo "REPLACE_HISTORY must be 1 (got '$REPLACE_HISTORY')." >&2
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

# 4. V2 should hold no readings from a station's V1 period that weren't
#    imported from V1 (test readings, for example). Readings from stations
#    already reflashed come after their last V1 reading and are fine.
V1_LAST="SELECT CAST(TRIM(location) AS UNSIGNED) AS station_id, MAX(recTime) AS last_v1
         FROM v1_import.IAQ_SEN55 WHERE TRIM(location) REGEXP '^[0-9]+\$' GROUP BY 1"
NOT_IMPORTED=""
if [ -n "$(mariadb -N -e "SELECT 1 FROM information_schema.TABLES WHERE TABLE_SCHEMA = 'buildingData' AND TABLE_NAME = 'v1_conversion'")" ]; then
  NOT_IMPORTED="AND r.station_id NOT IN (SELECT station_id FROM v1_conversion)"
fi
OVERLAP=$(mariadb -N buildingData -e "SELECT COUNT(*) FROM sen55_readings r JOIN ($V1_LAST) v
  ON v.station_id = r.station_id WHERE r.measured_at <= v.last_v1 $NOT_IMPORTED")
if [ "$OVERLAP" -gt 0 ] && [ "${REPLACE_HISTORY:-0}" != 1 ]; then
  echo "This V2 database already has $OVERLAP readings from before some stations'"
  echo "last V1 reading, probably from testing. They would be mixed into the history."
  echo "To delete them and import, run this again with REPLACE_HISTORY=1:"
  echo "  sudo REPLACE_HISTORY=1 bash $0 $EXPORT"
  read -rp "Continue anyway and keep them? [y/N] " ANSWER || ANSWER=n
  [[ "$ANSWER" =~ ^[Yy] ]] || exit 1
fi

# 5. Copy into the V2 tables
echo "Copying readings and station names into V2..."
{ echo "SET @v1_temp_scale := ${V1_TEMP_SCALE:-NULL}, @v1_rh_unscale := ${V1_RH_UNSCALE:-NULL}, @replace_history := ${REPLACE_HISTORY:-NULL};"
  cat "$HERE/import_v1.sql"
} | mariadb -t

# The dashboard's queries need up-to-date statistics after a bulk load
mariadb buildingData -e "ANALYZE TABLE sen55_readings, stations, station_calibration" >/dev/null

echo
echo "Done. Check the dashboard, then remove the staging copy when you're satisfied:"
echo "  sudo mariadb -e \"DROP DATABASE v1_import\""
