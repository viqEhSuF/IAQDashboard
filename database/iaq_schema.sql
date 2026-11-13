-- IAQ database, fresh install
--
-- For MariaDB 11.8 on 64-bit Raspberry Pi OS (Trixie). On the 64-bit OS,
-- TIMESTAMP columns run to 2106; on a 32-bit OS they stop in 2038.
--
-- Edit the two passwords in section 5, then run on the Pi:
--   sudo mariadb < iaq_schema.sql
-- The ingest password must match IAQ_DB_PASS in /etc/iaq/config.php, and the
-- dashboard password must match MYSQL_PASS in the sensor-api service.
-- Never commit the real passwords to the repository.
--
-- Stations (IAQ_SEN55_station.ino) post raw values in native units
-- (deg C, %, ug/m3, ppb, ppm) to iaq_ingest.php, which inserts them here.
-- Per-station calibration lives in station_calibration and is applied by the
-- views when the dashboard queries them, so it can be changed or corrected
-- later without touching stored data or reflashing a station.

CREATE DATABASE IF NOT EXISTS buildingData CHARACTER SET utf8mb4;
USE buildingData;

-- ---------------------------------------------------------------------------
-- 1. Stations
--    station_id is the LOCATION number compiled into the station firmware.
--    The ingest script adds an unnamed row the first time a new number posts.
-- ---------------------------------------------------------------------------
CREATE TABLE stations (
  station_id    SMALLINT UNSIGNED NOT NULL,
  name          VARCHAR(64)  NULL,                    -- e.g. 'Living room'
  station_type  VARCHAR(16)  NOT NULL DEFAULT 'sen55',
  firmware      VARCHAR(32)  NULL,                    -- updated by the ingest script on each post
  active        TINYINT(1)   NOT NULL DEFAULT 1,      -- 0 hides it from station_health
  notes         VARCHAR(255) NULL,
  PRIMARY KEY (station_id)
) ENGINE=InnoDB;

-- ---------------------------------------------------------------------------
-- 2. Calibration, with the period each value applies to
--    corrected = raw * slope + offset_val
--    metric: 'temp_c'  enclosure self-heating, in deg C (RH is recalculated
--                      from it in sen55_display, so RH needs no row)
--            'pm'      all four PM sizes
--            'hcho'    SFA30 formaldehyde, ppb
--            'co2'     SCD40, ppm
--    Each reading uses the row whose period contains its measured_at, so
--    changing offset_val on a row re-renders that whole period.
--    Keep periods for the same station and metric from overlapping.
-- ---------------------------------------------------------------------------
CREATE TABLE station_calibration (
  cal_id      INT UNSIGNED NOT NULL AUTO_INCREMENT,
  station_id  SMALLINT UNSIGNED NOT NULL,
  metric      VARCHAR(16)   NOT NULL,
  slope       DECIMAL(8,5)  NOT NULL DEFAULT 1,
  offset_val  DECIMAL(8,3)  NOT NULL DEFAULT 0,
  valid_from  TIMESTAMP     NOT NULL DEFAULT CURRENT_TIMESTAMP,
  valid_to    TIMESTAMP     NULL DEFAULT NULL,        -- NULL = still in effect
  note        VARCHAR(128)  NULL,
  PRIMARY KEY (cal_id),
  KEY idx_lookup (station_id, metric, valid_from),
  CONSTRAINT chk_cal_metric CHECK (metric IN ('temp_c', 'pm', 'hcho', 'co2')),
  CONSTRAINT fk_cal_station FOREIGN KEY (station_id) REFERENCES stations (station_id)
) ENGINE=InnoDB;

-- ---------------------------------------------------------------------------
-- 3. Readings: raw values plus station health
--    measured_at is set by the database on insert. The column also accepts a
--    time sent by the station, if stations ever send one.
--    The primary key keeps each station's readings stored in time order, so
--    dashboard queries for one station over a time range read only that range.
-- ---------------------------------------------------------------------------
CREATE TABLE sen55_readings (
  station_id     SMALLINT UNSIGNED NOT NULL,
  measured_at    TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,

  temp_c   DECIMAL(5,2)  NULL,                    -- deg C
  rh       DECIMAL(5,2)  NULL,                    -- %
  pm1      DECIMAL(6,1)  NULL,                    -- ug/m3
  pm25     DECIMAL(6,1)  NULL,
  pm4      DECIMAL(6,1)  NULL,
  pm10     DECIMAL(6,1)  NULL,
  voc      DECIMAL(4,1)  NULL,                    -- index, 1-500
  nox      DECIMAL(4,1)  NULL,                    -- index, 1-500
  hcho     DECIMAL(6,1)  NULL,                    -- ppb
  co2      SMALLINT UNSIGNED NULL,                -- ppm

  sen55_status  INT UNSIGNED NULL,                -- SEN55 device status register, read-and-cleared each report
  rssi_dbm      TINYINT      NULL,                -- WiFi signal strength
  uptime_s      INT UNSIGNED NULL,                -- seconds since the station booted

  PRIMARY KEY (station_id, measured_at),
  KEY idx_measured (measured_at),
  CONSTRAINT fk_reading_station FOREIGN KEY (station_id) REFERENCES stations (station_id)
) ENGINE=InnoDB;

-- ---------------------------------------------------------------------------
-- 4. Views
-- ---------------------------------------------------------------------------

-- Calibration applied, still in native units
CREATE OR REPLACE ALGORITHM = MERGE VIEW sen55_corrected AS
SELECT
  r.station_id,
  s.name AS station_name,
  r.measured_at,
  r.temp_c AS temp_c_raw,
  r.rh     AS rh_raw,
  IF(ct.cal_id IS NULL, r.temp_c, r.temp_c * ct.slope + ct.offset_val) AS temp_c,
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
--  * RH is recalculated at the corrected temperature (Magnus saturation vapor
--    pressure ratio): the water content is unchanged, only the temperature it
--    is referenced to changes. Capped at 100%.
--  * Dew point uses the raw temp/RH, because self-heating doesn't change it.
CREATE OR REPLACE ALGORITHM = MERGE VIEW sen55_display AS
SELECT
  c.station_id AS location,
  c.station_name,
  c.measured_at,
  ROUND(c.temp_c * 1.8 + 32, 1) AS temp,
  ROUND(LEAST(100, c.rh_raw * EXP(17.62 * c.temp_c_raw / (243.12 + c.temp_c_raw)
                                  - 17.62 * c.temp_c / (243.12 + c.temp_c))), 1) AS rH,
  ROUND(c.pm1, 1)  AS pmass1,
  ROUND(c.pm25, 1) AS pmass25,
  ROUND(c.pm4, 1)  AS pmass4,
  ROUND(c.pm10, 1) AS pmass10,
  c.voc AS VOC,
  c.nox AS NOx,
  ROUND(c.hcho, 1) AS HCHO,
  ROUND(c.co2, 0)  AS CO2,
  ROUND(IF(c.rh_raw > 0,
           243.12 * (LN(c.rh_raw / 100) + 17.62 * c.temp_c_raw / (243.12 + c.temp_c_raw))
             / (17.62 - (LN(c.rh_raw / 100) + 17.62 * c.temp_c_raw / (243.12 + c.temp_c_raw))),
           NULL) * 1.8 + 32, 1) AS DP
FROM sen55_corrected c;

-- One row per active station: last report, signal, and any SEN55 faults seen
-- in the last 24 hours.
-- Status bits: 4 fan error, 5 laser error, 6 RH/T sensor error,
-- 7 gas sensor error, 21 fan speed warning (19 = fan cleaning, informational).
CREATE OR REPLACE VIEW station_health AS
SELECT
  s.station_id,
  s.name,
  s.firmware,
  r.measured_at AS last_reading,
  TIMESTAMPDIFF(MINUTE, r.measured_at, NOW()) AS minutes_since_last,
  r.rssi_dbm,
  r.uptime_s,
  r.sen55_status AS status_last,
  d.status_24h,
  (d.status_24h >> 4)  & 1 AS fan_error_24h,
  (d.status_24h >> 5)  & 1 AS laser_error_24h,
  (d.status_24h >> 6)  & 1 AS rht_error_24h,
  (d.status_24h >> 7)  & 1 AS gas_sensor_error_24h,
  (d.status_24h >> 21) & 1 AS fan_speed_warning_24h
FROM stations s
LEFT JOIN (SELECT station_id, MAX(measured_at) AS last_at
           FROM sen55_readings GROUP BY station_id) m
       ON m.station_id = s.station_id
LEFT JOIN sen55_readings r
       ON r.station_id = m.station_id AND r.measured_at = m.last_at
LEFT JOIN (SELECT station_id, BIT_OR(sen55_status) AS status_24h
           FROM sen55_readings
           WHERE measured_at >= NOW() - INTERVAL 1 DAY
           GROUP BY station_id) d
       ON d.station_id = s.station_id
WHERE s.active = 1;

-- ---------------------------------------------------------------------------
-- 5. Accounts, each with only what it needs. Both are local-only.
--    Change the passwords before running. They are copied into every card
--    made from this image, which is acceptable only because MariaDB listens
--    on localhost alone (the Debian default).
-- ---------------------------------------------------------------------------

-- Ingest PHP: add readings, register new stations, update firmware versions
CREATE USER IF NOT EXISTS 'iaq_ingest'@'localhost' IDENTIFIED BY 'CHANGE_ME_INGEST';
GRANT SELECT, INSERT, UPDATE ON buildingData.stations       TO 'iaq_ingest'@'localhost';
GRANT INSERT                 ON buildingData.sen55_readings TO 'iaq_ingest'@'localhost';

-- Dashboard API (sensor-api): read everything, and rename stations from the
-- dashboard. It cannot change readings or calibration.
CREATE USER IF NOT EXISTS 'iaq_dashboard'@'localhost' IDENTIFIED BY 'CHANGE_ME_DASHBOARD';
GRANT SELECT        ON buildingData.*        TO 'iaq_dashboard'@'localhost';
GRANT UPDATE (name) ON buildingData.stations TO 'iaq_dashboard'@'localhost';

-- Calibration is managed as root:  sudo mariadb buildingData

-- ---------------------------------------------------------------------------
-- 6. Per-site setup, run after a card made from the image is installed.
--    Leave these out of the master image so it holds no site data.
-- ---------------------------------------------------------------------------
-- Stations register on their first post; name them from the dashboard.
--
-- Starting temperature correction for each station, then verify against a reference:
--   INSERT INTO station_calibration (station_id, metric, offset_val, note)
--   VALUES (1, 'temp_c', -1.9, 'starting estimate, verify'),
--          (2, 'temp_c', -1.9, 'starting estimate, verify'),
--          (3, 'temp_c', -1.9, 'starting estimate, verify');
--
-- To change a calibration from a given time onward, close the current row and
-- add a new one:
--   SET @t = '2026-12-01 09:00:00';
--   UPDATE station_calibration SET valid_to = @t
--    WHERE station_id = 1 AND metric = 'temp_c' AND valid_to IS NULL;
--   INSERT INTO station_calibration (station_id, metric, offset_val, valid_from, note)
--   VALUES (1, 'temp_c', -2.1, @t, 'checked against reference');
--
-- To correct a past period, UPDATE offset_val on that period's row.
