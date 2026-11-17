/**
 * Guideline levels drawn as dashed lines on the dashboard charts. Change the
 * values here to follow a different standard.
 *
 * These guidelines are averages over hours, while the charts show 2-minute
 * readings, so short peaks above a line (cooking, a full meeting room) are
 * expected. What matters is a level that stays above a line.
 */

export type Guideline = { value: number; label: string; color: string };

const WARNING = '#b45309';   // dark amber
const VERY_HIGH = '#b91c1c'; // dark red

export const GUIDELINES: Record<'co2' | 'pm25' | 'pm10' | 'hcho', Guideline[]> = {
  // CO2, German Environment Agency (UBA) indoor guide values (2008):
  // below 1000 ppm hygienically unobjectionable; 1000-2000 ppm conspicuous,
  // increase ventilation; above 2000 ppm unacceptable.
  // Health Canada's long-term limit for homes is also 1000 ppm (24-hour average).
  co2: [
    { value: 1000, label: 'Warning', color: WARNING },
    { value: 2000, label: 'Very high', color: VERY_HIGH }
  ],

  // PM2.5, 24-hour averages: WHO 2021 air quality guideline 15 ug/m3 (also
  // adopted for indoor air by the German Committee on Indoor Air Guide Values),
  // and the US EPA 24-hour standard of 35 ug/m3.
  pm25: [
    { value: 15, label: 'Warning', color: WARNING },
    { value: 35, label: 'Very high', color: VERY_HIGH }
  ],

  // PM10, 24-hour averages: WHO 2021 air quality guideline 45 ug/m3, and the
  // US EPA 24-hour standard of 150 ug/m3. The SEN55 calculates PM10 (and PM4)
  // from the particles it measures rather than measuring them directly.
  // PM1.0 and PM4.0 have no established guideline values.
  pm10: [
    { value: 45, label: 'Warning', color: WARNING },
    { value: 150, label: 'Very high', color: VERY_HIGH }
  ],

  // Formaldehyde, Health Canada residential indoor air quality guideline:
  // 40 ppb long-term (8-hour average) and 100 ppb short-term (1-hour average).
  hcho: [
    { value: 40, label: 'Warning', color: WARNING },
    { value: 100, label: 'Very high', color: VERY_HIGH }
  ]
};
