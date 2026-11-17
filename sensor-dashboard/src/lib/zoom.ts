/**
 * Shared pieces for drag-to-zoom on the charts.
 */

// Ignore drags shorter than this: a click, or a slip of the mouse
export const MIN_ZOOM_MS = 4 * 60 * 1000;

/** The points of a series that fall inside the zoom window (all of them when not zoomed) */
export function inZoom<T extends { x: number }>(points: T[], zoom: [number, number] | null): T[] {
  if (!zoom) return points;
  return points.filter(p => p.x >= zoom[0] && p.x <= zoom[1]);
}

/**
 * Formatter for time-axis labels, chosen by how much time the chart spans:
 * hours and minutes up to 6 hours, otherwise the date and hour.
 */
export function timeTickFormat(spanMs: number): (x: number) => string {
  if (spanMs > 0 && spanMs <= 6 * 3600 * 1000) {
    return (x: number) => new Date(x).toLocaleTimeString(undefined, { hour: 'numeric', minute: '2-digit' });
  }
  return (x: number) =>
    new Date(x).toLocaleString(undefined, { month: 'short', day: 'numeric', hour: '2-digit' });
}

const TICK_STEPS_MIN = [5, 10, 15, 30, 60, 120, 180, 360, 720, 1440];

/**
 * Tick positions on round local times, at most `maxTicks` of them: every
 * 5-30 minutes for short windows, every 1-24 hours (counted from local
 * midnight) for longer ones. Windows longer than 6 days return undefined and
 * keep the chart's own ticks.
 */
export function timeTicks(start: number, end: number, maxTicks = 6): number[] | undefined {
  const span = end - start;
  if (!(span > 0)) return undefined;
  const stepMin = TICK_STEPS_MIN.find(m => span / (m * 60000) <= maxTicks);
  if (stepMin === undefined) return undefined;
  const ticks: number[] = [];

  if (stepMin < 60) {
    const step = stepMin * 60000;
    const midnight = new Date(start);
    midnight.setHours(0, 0, 0, 0);
    for (let t = midnight.getTime() + Math.ceil((start - midnight.getTime()) / step) * step; t <= end; t += step) {
      ticks.push(t);
    }
  } else {
    // Whole hours, stepped on the local clock so daylight saving changes don't shift them
    const h = stepMin / 60;
    const d = new Date(start);
    d.setMinutes(0, 0, 0);
    d.setHours(Math.ceil(d.getHours() / h) * h);
    if (d.getTime() < start) d.setHours(d.getHours() + h);
    while (d.getTime() <= end) {
      ticks.push(d.getTime());
      d.setHours(d.getHours() + h);
    }
  }
  return ticks;
}

/** A zoom window as text, e.g. "3:10 PM – 4:40 PM" or "Nov 16, 3:10 PM – Nov 17, 9:00 AM" */
export function describeZoom(zoom: [number, number]): string {
  const a = new Date(zoom[0]), b = new Date(zoom[1]);
  const sameDay = a.toDateString() === b.toDateString();
  const time = { hour: 'numeric', minute: '2-digit' } as const;
  const dated = { month: 'short', day: 'numeric', hour: 'numeric', minute: '2-digit' } as const;
  return sameDay
    ? `${a.toLocaleTimeString(undefined, time)} – ${b.toLocaleTimeString(undefined, time)}`
    : `${a.toLocaleString(undefined, dated)} – ${b.toLocaleString(undefined, dated)}`;
}
