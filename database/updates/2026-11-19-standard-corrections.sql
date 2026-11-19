-- Update for systems created from iaq_schema.sql before 2026-11-19.
-- Adds standard corrections for the station build and a humidity correction:
--  * Humidity gets its own correction (metric 'rh'). The standard is x1.085,
--    from station 1 against an Aranet4; humidity was shown uncorrected before.
--  * Dew point now uses the corrected humidity as well as the corrected
--    temperature.
--  * New stations get the standard temperature (-3.6 C) and humidity
--    corrections automatically from their first reading.
--  * Existing stations get any standard correction they don't have yet, from
--    their first reading (or from their conversion time, for stations whose
--    V1 history was imported, since V1 readings are already corrected).
--    Corrections already set are kept.
-- Readings are unchanged. Safe to run more than once.
--
-- Run on the Pi:
--   sudo mariadb buildingData < ~/IAQDashboard/database/updates/2026-11-19-standard-corrections.sql

USE buildingData;

-- Allow humidity corrections
ALTER TABLE station_calibration DROP CONSTRAINT IF EXISTS chk_cal_metric;
ALTER TABLE station_calibration
  ADD CONSTRAINT chk_cal_metric CHECK (metric IN ('temp_c', 'rh', 'pm', 'hcho', 'co2'));

-- Standard corrections for the station build. A new station gets its own copy
-- of each, noted 'standard build', starting at its first reading (the trigger
-- below). Change a station's own row to override it; see section 6 for
-- changing the standard itself.
-- Values from station 1 against an Aranet4, 2026-11-16 to 11-19 (30-minute
-- means): temperature 3.55 C high, humidity x1.085 (rms 1.4 points).
CREATE TABLE IF NOT EXISTS calibration_defaults (
  metric      VARCHAR(16)   NOT NULL,
  slope       DECIMAL(8,5)  NOT NULL DEFAULT 1,
  offset_val  DECIMAL(8,3)  NOT NULL DEFAULT 0,
  note        VARCHAR(128)  NULL,
  PRIMARY KEY (metric),
  CONSTRAINT chk_default_metric CHECK (metric IN ('temp_c', 'rh', 'pm', 'hcho', 'co2'))
) ENGINE=InnoDB;

INSERT IGNORE INTO calibration_defaults (metric, slope, offset_val, note) VALUES
  ('temp_c', 1,     -3.6, 'enclosure self-heating'),
  ('rh',     1.085,  0,   'humidity sensor runs warm');

-- Runs when a station first posts (or is added any other way). Starts at the
-- moment the station is added, so it never reaches back into readings from
-- before it was registered, such as a converted site's V1 history.
CREATE OR REPLACE TRIGGER stations_standard_calibration
AFTER INSERT ON stations FOR EACH ROW
  INSERT INTO station_calibration (station_id, metric, slope, offset_val, valid_from, note)
  SELECT NEW.station_id, d.metric, d.slope, d.offset_val, NOW(), 'standard build'
  FROM calibration_defaults d;

-- Stations whose V1 history was imported (created here if no import has run,
-- so the step below can check it)
CREATE TABLE IF NOT EXISTS v1_conversion (
  station_id   SMALLINT UNSIGNED NOT NULL PRIMARY KEY,
  first_v1     TIMESTAMP NULL DEFAULT NULL,
  last_v1      TIMESTAMP NULL DEFAULT NULL,
  v1_readings  INT UNSIGNED NOT NULL DEFAULT 0,
  converted_at TIMESTAMP NULL DEFAULT NULL,
  imported_at  TIMESTAMP NULL DEFAULT NULL
) ENGINE=InnoDB COMMENT='V1 history imported by migration/import_v1.sh';

-- Existing stations: add each standard correction they don't have yet
INSERT INTO station_calibration (station_id, metric, slope, offset_val, valid_from, note)
SELECT s.station_id, d.metric, d.slope, d.offset_val,
       COALESCE(v.converted_at,
                (SELECT r.measured_at FROM sen55_readings r
                 WHERE r.station_id = s.station_id ORDER BY r.measured_at LIMIT 1),
                NOW()),
       'standard build'
FROM stations s
CROSS JOIN calibration_defaults d
LEFT JOIN v1_conversion v ON v.station_id = s.station_id
WHERE NOT EXISTS (SELECT 1 FROM station_calibration c
                  WHERE c.station_id = s.station_id AND c.metric = d.metric);

-- Calibration applied, still in native units
CREATE OR REPLACE ALGORITHM = MERGE VIEW sen55_corrected AS
SELECT
  r.station_id,
  s.name AS station_name,
  r.measured_at,
  r.temp_c AS temp_c_raw,
  r.rh     AS rh_raw,
  IF(ct.cal_id IS NULL, r.temp_c, r.temp_c * ct.slope + ct.offset_val) AS temp_c,
  IF(cr.cal_id IS NULL, r.rh, LEAST(100, GREATEST(0, r.rh * cr.slope + cr.offset_val))) AS rh,
  IF(cp.cal_id IS NULL, r.pm1,  r.pm1  * cp.slope + cp.offset_val) AS pm1,
  IF(cp.cal_id IS NULL, r.pm25, r.pm25 * cp.slope + cp.offset_val) AS pm25,
  IF(cp.cal_id IS NULL, r.pm4,  r.pm4  * cp.slope + cp.offset_val) AS pm4,
  IF(cp.cal_id IS NULL, r.pm10, r.pm10 * cp.slope + cp.offset_val) AS pm10,
  r.voc,
  r.nox,
  IF(ch.cal_id IS NULL, r.hcho, r.hcho * ch.slope + ch.offset_val) AS hcho,
  IF(cc.cal_id IS NULL, r.co2,  r.co2  * cc.slope + cc.offset_val) AS co2,
  r.sen55_status,
  r.rssi_dbm,
  r.uptime_s
FROM sen55_readings r
JOIN stations s ON s.station_id = r.station_id
LEFT JOIN station_calibration ct
  ON ct.station_id = r.station_id AND ct.metric = 'temp_c'
 AND r.measured_at >= ct.valid_from AND (ct.valid_to IS NULL OR r.measured_at < ct.valid_to)
LEFT JOIN station_calibration cr
  ON cr.station_id = r.station_id AND cr.metric = 'rh'
 AND r.measured_at >= cr.valid_from AND (cr.valid_to IS NULL OR r.measured_at < cr.valid_to)
LEFT JOIN station_calibration cp
  ON cp.station_id = r.station_id AND cp.metric = 'pm'
 AND r.measured_at >= cp.valid_from AND (cp.valid_to IS NULL OR r.measured_at < cp.valid_to)
LEFT JOIN station_calibration ch
  ON ch.station_id = r.station_id AND ch.metric = 'hcho'
 AND r.measured_at >= ch.valid_from AND (ch.valid_to IS NULL OR r.measured_at < ch.valid_to)
LEFT JOIN station_calibration cc
  ON cc.station_id = r.station_id AND cc.metric = 'co2'
 AND r.measured_at >= cc.valid_from AND (cc.valid_to IS NULL OR r.measured_at < cc.valid_to);

-- What the dashboard reads: the same column names and units as the old
-- IAQ_SEN55 table (temp and DP in deg F). If the dashboard expects a different
-- name for the timestamp column, change the measured_at alias here.
--  * Temperature and humidity have each station's corrections applied.
--  * Dew point is calculated (Magnus formula) from the corrected temperature
--    and corrected humidity, so all three agree with each other.
CREATE OR REPLACE ALGORITHM = MERGE VIEW sen55_display AS
SELECT
  c.station_id AS location,
  c.station_name,
  c.measured_at,
  ROUND(c.temp_c * 1.8 + 32, 1) AS temp,
  ROUND(c.rh, 1) AS rH,
  ROUND(c.pm1, 1)  AS pmass1,
  ROUND(c.pm25, 1) AS pmass25,
  ROUND(c.pm4, 1)  AS pmass4,
  ROUND(c.pm10, 1) AS pmass10,
  c.voc AS VOC,
  c.nox AS NOx,
  ROUND(c.hcho, 1) AS HCHO,
  ROUND(c.co2, 0)  AS CO2,
  ROUND(IF(c.rh > 0,
           243.12 * (LN(c.rh / 100) + 17.62 * c.temp_c / (243.12 + c.temp_c))
             / (17.62 - (LN(c.rh / 100) + 17.62 * c.temp_c / (243.12 + c.temp_c))),
           NULL) * 1.8 + 32, 1) AS DP
FROM sen55_corrected c;
