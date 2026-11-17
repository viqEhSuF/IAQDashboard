/**
 * IAQSen55 sensor data model that matches exactly what comes from the API.
 * A measurement is null when the station had no valid reading for it.
 */
export interface RawSensorData {
  location: string;
  recTime: string;
  timestamp: string;
  temp: number | null;
  rH: number | null;
  VOC: number | null;
  NOx: number | null;
  pmass1: number | null;
  pmass25: number | null;
  pmass4: number | null;
  pmass10: number | null;
  HCHO: number | null;
  CO2: number | null;
  indoorTd: number | null;
}

export interface LocationData {
  location: string;
}

/**
 * Normalized sensor data with consistent types
 */
export interface NormalizedSensorData {
  location: string;
  recTime: string;
  timestamp: string;
  temp: number | null;
  rH: number | null;
  VOC: number | null;
  NOx: number | null;
  pmass1: number | null;
  pmass25: number | null;
  pmass4: number | null;
  pmass10: number | null;
  HCHO: number | null;
  CO2: number | null;
  indoorTd: number | null;
}

/**
 * One station's status from /api/station-health. Fault flags cover the last
 * 24 hours.
 */
export interface StationHealth {
  location: string;
  name: string | null;
  firmware: string | null;
  lastReading: string | null;
  minutesSinceLast: number | null;
  rssi: number | null;
  uptimeS: number | null;
  fanError: boolean;
  laserError: boolean;
  rhtError: boolean;
  gasSensorError: boolean;
  fanSpeedWarning: boolean;
  // true when the last report had no readings from that sensor; null if the
  // station has never reported
  sen55NoData: boolean | null;
  co2NoData: boolean | null;
  hchoNoData: boolean | null;
}
