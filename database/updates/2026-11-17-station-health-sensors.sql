-- Update for systems created from iaq_schema.sql before 2026-11-17.
-- Adds whether each sensor (SEN55, SCD40 CO2, SFA30 HCHO) was in each
-- station's last report, for the dashboard's Station Health panel. Readings
-- and calibration are unchanged.
--
-- Run on the Pi:
--   sudo mariadb buildingData < ~/IAQDashboard/database/updates/2026-11-17-station-health-sensors.sql

USE buildingData;

-- One row per active station: last report, signal, whether each sensor was
-- in the last report, and any SEN55 faults seen in the last 24 hours.
-- A station sends a sensor's values empty when it got no valid reading from
-- it for the whole 2-minute interval, so *_no_data = 1 means that sensor is
-- not responding. *_no_data is NULL for a station that has never reported.
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
  IF(r.station_id IS NULL, NULL, r.temp_c IS NULL AND r.rh IS NULL AND r.pm25 IS NULL) AS sen55_no_data,
  IF(r.station_id IS NULL, NULL, r.co2 IS NULL)  AS co2_no_data,
  IF(r.station_id IS NULL, NULL, r.hcho IS NULL) AS hcho_no_data,
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
