-- Copies a V1 system's readings and station names into the V2 tables.
-- Run by import_v1.sh after it loads the V1 export into the staging database
-- v1_import. Safe to run again: readings already imported are skipped, station
-- names already set and temperature corrections already present are kept.
--
-- How V1 data is stored in V2:
--  * V1 stations corrected temperature and humidity in their firmware
--    (tempScale, rHscale), so V1 readings are stored as V1 recorded them and
--    no V2 correction applies to them.
--  * V2 firmware sends uncorrected readings. Each station gets a V2
--    temperature correction starting just after its own last V1 reading (its
--    conversion time, kept in v1_conversion), set to the same correction V1
--    used, so temperatures carry on without a step. It replaces the standard
--    temperature correction a station gets when it's added. Stations can be
--    reflashed at different times. Check the correction against a reference
--    and adjust it afterwards (conversion guide, step 7).
--  * Humidity uses the standard V2 correction (calibration_defaults, x1.085)
--    from the conversion time on, close to V1's own x1.116.
--  * Standard corrections never reach back into V1 history: any that start
--    before a station's conversion time (from bench testing, for example) are
--    moved to it.
--  * V1 "not available" codes and other out-of-range values become NULL (gaps).
--    Humidity that V1's scaling pushed above 100% (up to 112%) becomes 100.
--  * V1's stored dew point is not copied; V2 calculates it.

USE buildingData;

-- Settings. import_v1.sh sets them from V1_TEMP_SCALE, V1_RH_UNSCALE and
-- REPLACE_HISTORY when given; otherwise these defaults apply.
--
-- The V1 sketch's tempScale (near its top): V1 recorded deg F / tempScale.
-- The same value is used for every station; a station whose sketch had a
-- different one can be adjusted afterwards (conversion guide, step 7).
SET @v1_temp_scale := IFNULL(@v1_temp_scale, 1.034);

-- V1 recorded humidity multiplied by rHscale (1.116). 1 keeps it as V1
-- recorded it, which is within a few percent of V2's corrected humidity.
-- The V1 rHscale divides it back out, if V1's factor turns out to be wrong.
SET @v1_rh_unscale := IFNULL(@v1_rh_unscale, 1);

-- 1 deletes what V2 holds for each station up to its last V1 reading (an
-- earlier import, or test readings) before importing.
SET @replace_history := IFNULL(@replace_history, 0);

-- Handle V1 times without shifting them: TIMESTAMP columns are read in UTC
-- (as the export wrote them); DATETIME columns are local wall-clock times.
SET @rectime_type := (SELECT DATA_TYPE FROM information_schema.COLUMNS
                      WHERE TABLE_SCHEMA = 'v1_import' AND TABLE_NAME = 'IAQ_SEN55'
                        AND COLUMN_NAME = 'recTime');
SET time_zone = IF(@rectime_type = 'timestamp', '+00:00', 'SYSTEM');

-- Older V1 systems have no station names table
CREATE TABLE IF NOT EXISTS v1_import.location_names (
  location VARCHAR(50) NOT NULL PRIMARY KEY,
  name     VARCHAR(100) NOT NULL
);

-- V1 rows with a usable station number and time
CREATE OR REPLACE TEMPORARY TABLE v1_rows AS
SELECT CAST(TRIM(location) AS UNSIGNED) AS station_id, recTime, temp, rH / @v1_rh_unscale AS rH,
       pmass1, pmass25, pmass4, pmass10, VOC, NOx, HCHO, CO2
FROM v1_import.IAQ_SEN55
WHERE TRIM(location) REGEXP '^[0-9]+$'
  AND CAST(TRIM(location) AS UNSIGNED) BETWEEN 1 AND 65535
  AND recTime IS NOT NULL;

-- Each station's V1 period and conversion time (one second after its last V1
-- reading), kept for later runs. @run marks this run's stations.
CREATE TABLE IF NOT EXISTS v1_conversion (
  station_id   SMALLINT UNSIGNED NOT NULL PRIMARY KEY,
  first_v1     TIMESTAMP NULL DEFAULT NULL,
  last_v1      TIMESTAMP NULL DEFAULT NULL,
  v1_readings  INT UNSIGNED NOT NULL DEFAULT 0,
  converted_at TIMESTAMP NULL DEFAULT NULL,
  imported_at  TIMESTAMP NULL DEFAULT NULL
) ENGINE=InnoDB COMMENT='V1 history imported by migration/import_v1.sh';

SET @run := UNIX_TIMESTAMP();
INSERT INTO v1_conversion (station_id, first_v1, last_v1, v1_readings, converted_at, imported_at)
SELECT station_id, MIN(recTime), MAX(recTime), COUNT(*),
       FROM_UNIXTIME(UNIX_TIMESTAMP(MAX(recTime)) + 1), FROM_UNIXTIME(@run)
FROM v1_rows GROUP BY station_id
ON DUPLICATE KEY UPDATE first_v1 = VALUES(first_v1), last_v1 = VALUES(last_v1),
  v1_readings = VALUES(v1_readings), converted_at = VALUES(converted_at),
  imported_at = VALUES(imported_at);

-- Stations: one per V1 station number
INSERT IGNORE INTO stations (station_id, firmware, notes)
SELECT DISTINCT station_id, 'V1', 'Readings before the V2 conversion were imported from V1'
FROM v1_rows;

-- Station names from the V1 dashboard, where V2 has none yet
UPDATE stations s
JOIN v1_import.location_names n ON TRIM(n.location) = CAST(s.station_id AS CHAR)
SET s.name = LEFT(TRIM(n.name), 64)
WHERE s.name IS NULL AND TRIM(n.name) <> '';

-- Optionally clear each station's V1 period first (REPLACE_HISTORY=1)
DELETE r FROM sen55_readings r
JOIN v1_conversion c ON c.station_id = r.station_id
WHERE @replace_history = 1 AND r.measured_at <= c.last_v1
  AND UNIX_TIMESTAMP(c.imported_at) = @run;
SET @replaced := ROW_COUNT();

-- Readings. INSERT IGNORE skips a second reading for the same station and second.
INSERT IGNORE INTO sen55_readings
  (station_id, measured_at, temp_c, rh, pm1, pm25, pm4, pm10, voc, nox, hcho, co2)
SELECT
  station_id,
  recTime,
  IF((temp - 32) / 1.8 BETWEEN -40 AND 85, (temp - 32) / 1.8, NULL),
  CASE WHEN rH BETWEEN 0 AND 100 THEN rH
       WHEN rH > 100 AND rH <= 112 THEN 100
       ELSE NULL END,
  IF(pmass1  BETWEEN 0 AND 1000, pmass1,  NULL),
  IF(pmass25 BETWEEN 0 AND 1000, pmass25, NULL),
  IF(pmass4  BETWEEN 0 AND 1000, pmass4,  NULL),
  IF(pmass10 BETWEEN 0 AND 1000, pmass10, NULL),
  IF(VOC  BETWEEN 0 AND 500,    VOC,  NULL),
  IF(NOx  BETWEEN 0 AND 500,    NOx,  NULL),
  IF(HCHO BETWEEN -50 AND 1000, HCHO, NULL),
  IF(CO2  BETWEEN 1 AND 40000,  ROUND(CO2), NULL)
FROM v1_rows;

-- V2 temperature correction for each imported station from its conversion
-- time on, matching V1's. It replaces the standard one the station got when it
-- was added; a correction already set for the station is kept.
-- V1's deg F / tempScale is, in deg C: raw * (1 / tempScale) + (32 / tempScale - 32) / 1.8
DELETE k FROM station_calibration k
JOIN v1_conversion c ON c.station_id = k.station_id
WHERE UNIX_TIMESTAMP(c.imported_at) = @run
  AND k.metric = 'temp_c' AND k.note = 'standard build';

INSERT INTO station_calibration (station_id, metric, slope, offset_val, valid_from, note)
SELECT c.station_id, 'temp_c',
       1 / @v1_temp_scale, (32 / @v1_temp_scale - 32) / 1.8,
       c.converted_at,
       CONCAT('V2 readings from the conversion on; same as V1 tempScale ', @v1_temp_scale)
FROM v1_conversion c
WHERE UNIX_TIMESTAMP(c.imported_at) = @run
  AND NOT EXISTS (SELECT 1 FROM station_calibration k
                  WHERE k.station_id = c.station_id AND k.metric = 'temp_c');

-- Standard corrections start at the conversion time at the earliest
UPDATE station_calibration k
JOIN v1_conversion c ON c.station_id = k.station_id
SET k.valid_from = c.converted_at
WHERE UNIX_TIMESTAMP(c.imported_at) = @run
  AND k.note = 'standard build' AND k.valid_from < c.converted_at;

-- ---------------------------------------------------------------------------
-- Summary, in local time
-- ---------------------------------------------------------------------------
SET time_zone = 'SYSTEM';

SELECT
  x.station_id AS station,
  IFNULL(s.name, '(unnamed)') AS name,
  x.v1_readings,
  x.in_v2,
  x.v1_readings - x.in_v2 AS duplicates_skipped,
  x.first_v1 AS first_reading,
  x.last_v1 AS last_v1_reading,
  x.converted_at AS conversion_time
FROM (SELECT c.*,
             (SELECT COUNT(*) FROM sen55_readings r
              WHERE r.station_id = c.station_id AND r.measured_at <= c.last_v1) AS in_v2
      FROM v1_conversion c
      WHERE UNIX_TIMESTAMP(c.imported_at) = @run) x
LEFT JOIN stations s ON s.station_id = x.station_id
ORDER BY x.station_id;

SELECT
  (SELECT COUNT(*) FROM v1_import.IAQ_SEN55) - (SELECT COUNT(*) FROM v1_rows)
    AS v1_rows_without_a_station_number_or_time,
  IF(@v1_rh_unscale = 1, 'as V1 recorded it', CONCAT('divided by ', @v1_rh_unscale))
    AS v1_humidity,
  IF(@replace_history = 1, @replaced, 'kept') AS earlier_readings_replaced;

-- Corrections set for a station that would also apply to its V1 readings,
-- which were already corrected. Run the command in the fix column for each
-- row listed.
SELECT k.station_id AS station, k.metric, k.slope, k.offset_val, k.valid_from,
       c.converted_at AS conversion_time,
       'Also applies to V1 readings' AS warning,
       CONCAT('sudo mariadb buildingData -e "UPDATE station_calibration SET valid_from = ''',
              c.converted_at, ''' WHERE cal_id = ', k.cal_id, '"') AS fix
FROM station_calibration k
JOIN v1_conversion c ON c.station_id = k.station_id
WHERE k.metric IN ('temp_c', 'rh') AND k.valid_from < c.converted_at
  AND UNIX_TIMESTAMP(c.imported_at) = @run;

SELECT k.station_id AS station, k.metric, k.slope, k.offset_val, k.valid_from AS from_time,
       IF(k.metric = 'temp_c', ROUND((k.slope * 25 + k.offset_val - 25) * 1.8, 1), NULL) AS change_at_77F,
       IF(k.metric = 'rh', ROUND(k.slope * 50 + k.offset_val, 1), NULL) AS rh_50_shows_as
FROM station_calibration k
JOIN v1_conversion c ON c.station_id = k.station_id
WHERE k.metric IN ('temp_c', 'rh') AND UNIX_TIMESTAMP(c.imported_at) = @run
ORDER BY k.station_id, k.metric, k.valid_from;
