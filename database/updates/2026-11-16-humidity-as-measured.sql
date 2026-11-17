-- Update for systems created from iaq_schema.sql before 2026-11-16.
-- Humidity is shown as the SEN55 reports it, no longer recalculated from the
-- corrected temperature, and dew point is calculated from the corrected
-- temperature and that humidity. Temperature corrections are unchanged, and
-- no stored data is changed.
--
-- Run on the Pi:
--   sudo mariadb buildingData < ~/IAQDashboard/database/updates/2026-11-16-humidity-as-measured.sql

USE buildingData;

-- What the dashboard reads: the same column names and units as the old
-- IAQ_SEN55 table (temp and DP in deg F). If the dashboard expects a different
-- name for the timestamp column, change the measured_at alias here.
--  * Temperature has each station's correction applied.
--  * Humidity is shown as the SEN55 reports it. The temperature correction
--    does not change it: against a reference meter, the SEN55's humidity
--    matches the room even while its temperature reads high.
--  * Dew point is calculated (Magnus formula) from the corrected temperature
--    and the humidity shown, so all three agree with each other.
CREATE OR REPLACE ALGORITHM = MERGE VIEW sen55_display AS
SELECT
  c.station_id AS location,
  c.station_name,
  c.measured_at,
  ROUND(c.temp_c * 1.8 + 32, 1) AS temp,
  ROUND(c.rh_raw, 1) AS rH,
  ROUND(c.pm1, 1)  AS pmass1,
  ROUND(c.pm25, 1) AS pmass25,
  ROUND(c.pm4, 1)  AS pmass4,
  ROUND(c.pm10, 1) AS pmass10,
  c.voc AS VOC,
  c.nox AS NOx,
  ROUND(c.hcho, 1) AS HCHO,
  ROUND(c.co2, 0)  AS CO2,
  ROUND(IF(c.rh_raw > 0,
           243.12 * (LN(c.rh_raw / 100) + 17.62 * c.temp_c / (243.12 + c.temp_c))
             / (17.62 - (LN(c.rh_raw / 100) + 17.62 * c.temp_c / (243.12 + c.temp_c))),
           NULL) * 1.8 + 32, 1) AS DP
FROM sen55_corrected c;
