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
--    temperature correction starting just after its last V1 reading (the
--    conversion time), set to the same correction V1 used, so temperatures
--    carry on without a step. Check it against a reference and adjust it
--    afterwards (conversion guide, step 7).
--  * V1 "not available" codes and other out-of-range values become NULL (gaps).
--    Humidity that V1's scaling pushed above 100% (up to 112%) becomes 100.
--  * V1's stored dew point is not copied; V2 calculates it.

USE buildingData;

-- Settings. import_v1.sh sets them from V1_TEMP_SCALE and V1_RH_UNSCALE when
-- given; otherwise these defaults apply.
--
-- The V1 sketch's tempScale (near its top): V1 recorded deg F / tempScale.
-- The same value is used for every station; a station whose sketch had a
-- different one can be adjusted afterwards (conversion guide, step 7).
SET @v1_temp_scale := IFNULL(@v1_temp_scale, 1.034);

-- V2 shows humidity as measured; V1 recorded it multiplied by rHscale.
-- 1 keeps V1 humidity as V1 recorded it. The V1 rHscale (1.116) divides it
-- back out, so the history matches V2's uncorrected humidity.
SET @v1_rh_unscale := IFNULL(@v1_rh_unscale, 1);

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

-- Conversion time: one second after the last V1 reading
SET @cutover_unix := (SELECT UNIX_TIMESTAMP(MAX(recTime)) + 1 FROM v1_rows);

-- Stations: one per V1 station number
INSERT IGNORE INTO stations (station_id, firmware, notes)
SELECT DISTINCT station_id, 'V1', 'Readings before the V2 conversion were imported from V1'
FROM v1_rows;

-- Station names from the V1 dashboard, where V2 has none yet
UPDATE stations s
JOIN v1_import.location_names n ON TRIM(n.location) = CAST(s.station_id AS CHAR)
SET s.name = LEFT(TRIM(n.name), 64)
WHERE s.name IS NULL AND TRIM(n.name) <> '';

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

-- V2 temperature correction for each imported station from the conversion
-- time on, unless the station already has one. V1's deg F / tempScale is, in
-- deg C: raw * (1 / tempScale) + (32 / tempScale - 32) / 1.8
INSERT INTO station_calibration (station_id, metric, slope, offset_val, valid_from, note)
SELECT DISTINCT r.station_id, 'temp_c',
       1 / @v1_temp_scale, (32 / @v1_temp_scale - 32) / 1.8,
       FROM_UNIXTIME(@cutover_unix),
       CONCAT('V2 readings from the conversion on; same as V1 tempScale ', @v1_temp_scale)
FROM v1_rows r
WHERE NOT EXISTS (SELECT 1 FROM station_calibration c
                  WHERE c.station_id = r.station_id AND c.metric = 'temp_c');

-- ---------------------------------------------------------------------------
-- Summary, in local time
-- ---------------------------------------------------------------------------
SET time_zone = 'SYSTEM';

SELECT
  v.station_id AS station,
  IFNULL(s.name, '(unnamed)') AS name,
  v.v1_readings,
  IFNULL(i.imported, 0) AS in_v2,
  v.v1_readings - IFNULL(i.imported, 0) AS duplicates_skipped,
  v.first_reading,
  v.last_reading
FROM (SELECT station_id, COUNT(*) AS v1_readings,
             FROM_UNIXTIME(MIN(UNIX_TIMESTAMP(recTime))) AS first_reading,
             FROM_UNIXTIME(MAX(UNIX_TIMESTAMP(recTime))) AS last_reading
      FROM v1_rows GROUP BY station_id) v
LEFT JOIN (SELECT station_id, COUNT(*) AS imported
           FROM sen55_readings
           WHERE measured_at < FROM_UNIXTIME(@cutover_unix)
           GROUP BY station_id) i ON i.station_id = v.station_id
LEFT JOIN stations s ON s.station_id = v.station_id
ORDER BY v.station_id;

SELECT
  (SELECT COUNT(*) FROM v1_import.IAQ_SEN55) - (SELECT COUNT(*) FROM v1_rows)
    AS v1_rows_without_a_station_number_or_time,
  FROM_UNIXTIME(@cutover_unix) AS conversion_time,
  IF(@v1_rh_unscale = 1, 'as V1 recorded it', CONCAT('divided by ', @v1_rh_unscale))
    AS v1_humidity;

-- Temperature corrections that would also apply to the imported V1 readings.
-- V1 readings were already corrected, so any row listed here should start at
-- the conversion time instead.
SELECT c.station_id AS station, c.slope, c.offset_val, c.valid_from, c.valid_to,
       'Also applies to V1 readings: move valid_from to the conversion time' AS warning
FROM station_calibration c
WHERE c.metric = 'temp_c'
  AND c.valid_from < FROM_UNIXTIME(@cutover_unix)
  AND c.station_id IN (SELECT station_id FROM v1_rows);

SELECT c.station_id AS station, c.slope, c.offset_val, c.valid_from AS from_time,
       ROUND((c.slope * 25 + c.offset_val - 25) * 1.8, 1) AS change_at_77F
FROM station_calibration c
WHERE c.metric = 'temp_c' AND c.station_id IN (SELECT station_id FROM v1_rows)
ORDER BY c.station_id, c.valid_from;
