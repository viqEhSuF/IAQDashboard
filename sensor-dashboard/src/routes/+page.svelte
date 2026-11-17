<script lang="ts">
  import { onMount } from 'svelte';
  import LineChart from '$lib/Components/LineChart.svelte';
  import MultiLineChart from '$lib/Components/MultiLineChart.svelte';
  import type { NormalizedSensorData, LocationData, StationHealth } from '$lib/models';
  import { getApiUrl } from '$lib/config';
  import { GUIDELINES } from '$lib/guidelines';
  
  // Define data record type that matches the LineChart component
  type DataRecord = {
    x: number;
    y: number;
  };
  
  // State variables
  let sensorData: NormalizedSensorData[] = [];
  let tempChart: DataRecord[] = [];
  let co2Chart: DataRecord[] = [];
  let humidityChart: DataRecord[] = [];
  let vocChart: DataRecord[] = [];
  let pmassChart: DataRecord[] = [];
  let noxChart: DataRecord[] = [];
  let hchoChart: DataRecord[] = [];
  let dpChart: DataRecord[] = [];
  let loading = true;
  let error: string | null = null;

  // Location filter
  let availableLocations: LocationData[] = [];
  let selectedLocation: string | null = null;

  // Station names, stored in the database as { "1": "Living Room", ... }
  let locationNames: Record<string, string> = {};
  let editingLocation: string | null = null;
  let editingValue = '';

  function locationLabel(loc: string): string {
    return locationNames[loc]?.trim() || `Location ${loc}`;
  }

  function startEdit(loc: string) {
    editingLocation = loc;
    editingValue = locationNames[loc] ?? '';
  }

  function saveEdit() {
    if (editingLocation === null) return;
    const trimmed = editingValue.trim();
    const loc = editingLocation;
    editingLocation = null;

    if (trimmed) {
      locationNames = { ...locationNames, [loc]: trimmed };
      fetch(getApiUrl(`location-names/${loc}`), {
        method: 'PUT',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ name: trimmed })
      }).catch(err => console.error('Failed to save location name:', err));
    } else {
      const { [loc]: _, ...rest } = locationNames;
      locationNames = rest;
      fetch(getApiUrl(`location-names/${loc}`), { method: 'DELETE' })
        .catch(err => console.error('Failed to delete location name:', err));
    }
  }

  // Svelte action: focus an input as soon as it mounts.
  function focusOnMount(node: HTMLInputElement) {
    node.focus();
    node.select();
  }

  // Date range filters
  let startDate: string = '';
  let endDate: string = '';
  let startHour: number = 0;
  let endHour: number = 23;
  
  // Time formatter options for X-axis
  function getTimeFormat() {
    if (!tempChart.length) return undefined;
    
    // Calculate time span in hours
    const firstTimestamp = Math.min(...tempChart.map(d => d.x));
    const lastTimestamp = Math.max(...tempChart.map(d => d.x));
    const timeSpanHours = (lastTimestamp - firstTimestamp) / (1000 * 60 * 60);
    
    // Choose appropriate time format based on data range
    if (timeSpanHours <= 24) {
      // For 24 hours or less, show hour:minute
      return (d: any) => {
        const date = new Date(d);
        return date.toLocaleTimeString(undefined, { hour: '2-digit', minute: '2-digit' });
      };
    } else if (timeSpanHours <= 72) {
      // For 3 days or less, show day and time
      return (d: any) => {
        const date = new Date(d);
        return date.toLocaleString(undefined, { 
          weekday: 'short',
          hour: '2-digit', 
          minute: '2-digit'
        });
      };
    } else {
      // For longer periods, show month/day and hour
      return (d: any) => {
        const date = new Date(d);
        return date.toLocaleString(undefined, { 
          month: 'short', 
          day: 'numeric',
          hour: '2-digit'
        });
      };
    }
  }
  
  // Reactive axis options
  $: xAxisOptions = {
    tickFormat: getTimeFormat(),
    numTicks: 5,
    gridLine: true
  };
  
  $: tempAxisOptions = {
    minValue: tempChart.length ? Math.min(...tempChart.map(d => d.y).filter(v => !isNaN(v))) - 5 : 60,
    maxValue: tempChart.length ? Math.max(...tempChart.map(d => d.y).filter(v => !isNaN(v))) + 5 : 80,
  };
  
  $: co2AxisOptions = {
    minValue: 0,
    maxValue: co2Chart.length ? Math.max(...co2Chart.map(d => d.y).filter(v => !isNaN(v))) + 100 : 2000,
  };
  
  $: vocAxisOptions = {
    minValue: 1,
    maxValue: 500,
  };
  
  $: pmAxisOptions = {
    minValue: 0,
    maxValue: pmassChart.length ? Math.max(...pmassChart.map(d => d.y).filter(v => !isNaN(v))) * 1.2 : 50,
  };

  $: noxAxisOptions = {
    minValue: 1,
    maxValue: 500,
  };

  $: hchoAxisOptions = {
    minValue: 0,
    maxValue: hchoChart.length ? Math.max(...hchoChart.map(d => d.y).filter(v => !isNaN(v))) * 1.2 : 100,
  };

  $: dpAxisOptions = {
    minValue: dpChart.length ? Math.min(...dpChart.map(d => d.y).filter(v => !isNaN(v))) - 5 : 30,
    maxValue: dpChart.length ? Math.max(...dpChart.map(d => d.y).filter(v => !isNaN(v))) + 5 : 70,
  };
  
  // ── Time range and live refresh ────────────────────────────────────────

  // Stations report every 2 minutes, so the page refreshes on the same cycle
  const REFRESH_MS = 120000;

  // Hours back from now for a preset button ("Last 6 Hours" = 6). A preset
  // range moves forward with each refresh. null = a range picked by hand.
  let presetHours: number | null = 24;
  let lastUpdated: Date | null = null;
  let refreshFailed = false;
  let lastRefresh = 0;
  let fetchSeq = 0;

  // YYYY-MM-DD in the browser's local time (toISOString gives the UTC date,
  // which is already tomorrow in the evening in US time zones)
  function localDate(d: Date): string {
    const m = String(d.getMonth() + 1).padStart(2, '0');
    const day = String(d.getDate()).padStart(2, '0');
    return `${d.getFullYear()}-${m}-${day}`;
  }

  // Sets the range to the last `hours` hours, to the hour
  function applyPreset(hours: number) {
    const now = new Date();
    const start = new Date(now.getTime() - hours * 3600 * 1000);
    startDate = localDate(start);
    startHour = start.getHours();
    endDate = localDate(now);
    endHour = now.getHours();
  }

  function selectPreset(hours: number) {
    presetHours = hours;
    applyPreset(hours);
    fetchData();
  }

  // True while new readings can still fall inside the range
  function isLive(preset: number | null, end: string, hour: number, _updated: Date | null): boolean {
    if (preset !== null || !end) return true;
    return new Date(`${end}T${hour.toString().padStart(2, '0')}:59:59`).getTime() >= Date.now();
  }
  $: rangeLive = isLive(presetHours, endDate, endHour, lastUpdated);

  // Runs every 2 minutes, and when a hidden tab comes back into view.
  // Updates the charts in place, without the loading spinner.
  function refresh() {
    if (document.hidden) return;
    lastRefresh = Date.now();
    fetchStationHealth();
    fetchLocations();
    if (loading || !isLive(presetHours, endDate, endHour, null)) return;
    if (presetHours !== null) applyPreset(presetHours);
    fetchData(true);
  }

  // Set default date range to last 24 hours
  function setDefaultDateRange() {
    presetHours = 24;
    applyPreset(24);
  }
  
  // Format hour for display
  function formatHour(hour: number): string {
    return hour.toString().padStart(2, '0') + ':00';
  }
  
  // Get hours array for selector
  function getHours(): {value: number, label: string}[] {
    const hours = [];
    for (let i = 0; i <= 23; i++) {
      hours.push({
        value: i,
        label: formatHour(i)
      });
    }
    return hours;
  }
  
  // Hours for selection
  const hours = getHours();
  
  // Fetch available sensor locations
  async function fetchLocations() {
    try {
      const response = await fetch(getApiUrl('locations'));
      if (response.ok) {
        availableLocations = (await response.json()) ?? [];
        if (selectedLocation === null && availableLocations.length > 0) {
          selectedLocation = availableLocations[0].location;
        }
      }
    } catch (err) {
      console.error('Error fetching locations:', err);
    }
  }

  // Fetch data with the current date range and selected location.
  // quiet = a background refresh: no spinner, and the charts stay up if it fails.
  async function fetchData(quiet = false) {
    const seq = ++fetchSeq;
    if (!quiet) {
      loading = true;
      error = null;
    }
    try {
      const url = new URL(getApiUrl('sensor-data'), window.location.origin);
      if (selectedLocation !== null) url.searchParams.append('location', selectedLocation);
      if (startDate) url.searchParams.append('startDate', `${startDate}T${startHour.toString().padStart(2, '0')}:00:00`);
      if (endDate)   url.searchParams.append('endDate',   `${endDate}T${endHour.toString().padStart(2, '0')}:59:59`);
      const response = await fetch(url);
      if (!response.ok) throw new Error(`HTTP error: ${response.status}`);
      const data = (await response.json()) ?? [];
      if (seq !== fetchSeq) return;  // a newer request replaced this one
      sensorData = data;
      updateCharts();
      error = null;
      refreshFailed = false;
      lastUpdated = new Date();
    } catch (err) {
      if (seq !== fetchSeq) return;
      console.error('Error fetching data:', err);
      if (quiet && sensorData.length > 0) {
        refreshFailed = true;  // keep showing the last data; the next refresh retries
      } else {
        error = err instanceof Error ? err.message : 'Unknown error';
      }
    } finally {
      if (seq === fetchSeq) loading = false;
    }
  }

  // Handle date input changes: a range picked by hand stays where it is
  function handleDateChange() {
    presetHours = null;
    fetchData();
  }

  // Reset date filters and fetch all data
  function resetDateFilters() {
    presetHours = null;
    startDate = '';
    endDate = '';
    startHour = 0;
    endHour = 23;
    fetchData();
  }
  
  // Update all chart data
  function updateCharts() {
    tempChart = createTimeSeriesData(sensorData, 'temp');
    co2Chart = createTimeSeriesData(sensorData, 'CO2');
    humidityChart = createTimeSeriesData(sensorData, 'rH');
    vocChart = createTimeSeriesData(sensorData, 'VOC');
    pmassChart = createTimeSeriesData(sensorData, 'pmass25');
    noxChart = createTimeSeriesData(sensorData, 'NOx');
    hchoChart = createTimeSeriesData(sensorData, 'HCHO');
    dpChart = createTimeSeriesData(sensorData, 'indoorTd');
  }
  
  // Decimal places each measure is shown with. Values are rounded to this
  // before plotting, so the line only moves when the displayed number changes.
  const FIELD_DECIMALS: Partial<Record<keyof NormalizedSensorData, number>> = {
    pmass1: 1, pmass25: 1, pmass4: 1, pmass10: 1, HCHO: 1
  };

  function roundTo(v: number, decimals: number): number {
    const f = 10 ** decimals;
    return Math.round(v * f) / f;
  }

  // Readings with no value for this field (null) are left out rather than
  // plotted as zero
  function createTimeSeriesData(data: NormalizedSensorData[], field: keyof NormalizedSensorData): DataRecord[] {
    const decimals = FIELD_DECIMALS[field] ?? 0;
    return data
      .filter(d => d[field] !== null && d[field] !== undefined)
      .map(d => ({
        x: new Date(d.recTime).getTime(),
        y: roundTo(Number(d[field]), decimals)
      }))
      .sort((a, b) => a.x - b.x);
  }

  // ── Station health ─────────────────────────────────────────────────────

  let stationHealth: StationHealth[] = [];

  // A station reports every 2 minutes; 10 minutes means several missed reports
  const OFFLINE_MINUTES = 10;
  const WEAK_RSSI_DBM = -75;

  async function fetchStationHealth() {
    try {
      const response = await fetch(getApiUrl('station-health'));
      if (response.ok) stationHealth = (await response.json()) ?? [];
    } catch (err) {
      console.error('Error fetching station health:', err);
    }
  }

  type Level = 'ok' | 'warning' | 'fault' | 'unknown';
  type HealthRow = { label: string; level: Level; text: string };

  function lastSeen(m: number): string {
    if (m < 1) return 'Just now';
    if (m < 60) return `${m} min ago`;
    if (m < 48 * 60) return `${Math.round(m / 60)} h ago`;
    return `${Math.round(m / 1440)} days ago`;
  }

  function isOffline(s: StationHealth): boolean {
    return s.minutesSinceLast === null || s.minutesSinceLast > OFFLINE_MINUTES;
  }

  // One row per part of the station, each with its own status, so a weak
  // WiFi signal is never mistaken for a sensor fault. SEN55 fault flags cover
  // the last 24 hours; the other rows reflect the latest report.
  function healthRows(s: StationHealth): HealthRow[] {
    if (s.minutesSinceLast === null) {
      return [{ label: 'Reporting', level: 'unknown', text: 'No reports yet' }];
    }
    const offline = isOffline(s);
    const rows: HealthRow[] = [{
      label: 'Reporting',
      level: offline ? 'fault' : 'ok',
      text: offline ? `Offline, last report ${lastSeen(s.minutesSinceLast)}` : lastSeen(s.minutesSinceLast)
    }];

    rows.push(s.rssi === null
      ? { label: 'WiFi', level: 'unknown', text: 'No signal reading' }
      : s.rssi < WEAK_RSSI_DBM
        ? { label: 'WiFi', level: 'warning', text: `${s.rssi} dBm, weak` }
        : { label: 'WiFi', level: 'ok', text: `${s.rssi} dBm` });

    const sen55Faults: string[] = [];
    if (s.fanError) sen55Faults.push('Fan stopped');
    if (s.laserError) sen55Faults.push('PM laser fault');
    if (s.rhtError) sen55Faults.push('Temp/RH sensor fault');
    if (s.gasSensorError) sen55Faults.push('VOC/NOx sensor fault');
    rows.push(s.sen55NoData
      ? { label: 'SEN55', level: 'fault', text: 'No readings' }
      : sen55Faults.length
        ? { label: 'SEN55', level: 'fault', text: `${sen55Faults.join(', ')} (last 24 h)` }
        : s.fanSpeedWarning
          ? { label: 'SEN55', level: 'warning', text: 'Fan speed out of range (last 24 h)' }
          : { label: 'SEN55', level: 'ok', text: 'OK' });

    rows.push(s.co2NoData
      ? { label: 'CO₂ (SCD40)', level: 'fault', text: 'No readings' }
      : { label: 'CO₂ (SCD40)', level: 'ok', text: 'OK' });
    rows.push(s.hchoNoData
      ? { label: 'HCHO (SFA30)', level: 'fault', text: 'No readings' }
      : { label: 'HCHO (SFA30)', level: 'ok', text: 'OK' });

    // While a station is offline its other statuses are from its last report
    if (offline) rows.slice(1).forEach(r => (r.level = 'unknown'));
    return rows;
  }

  const LEVEL_STYLE: Record<Level, { dot: string; text: string }> = {
    ok:      { dot: 'bg-emerald-500', text: 'text-gray-600' },
    warning: { dot: 'bg-amber-400',   text: 'text-amber-700' },
    fault:   { dot: 'bg-red-500',     text: 'text-red-600' },
    unknown: { dot: 'bg-gray-300',    text: 'text-gray-400' }
  };

  // ── Overlay chart ───────────────────────────────────────────────────────

  const OVERLAY_COLORS = [
    '#ef4444', '#3b82f6', '#10b981', '#f59e0b',
    '#8b5cf6', '#f97316', '#06b6d4', '#ec4899',
    '#84cc16', '#14b8a6', '#a78bfa', '#fb923c'
  ];

  // decimals = decimal places shown in tooltips (only PM and HCHO need any)
  const OVERLAY_METRICS: { label: string; field: keyof NormalizedSensorData; decimals: number }[] = [
    { label: 'Temperature', field: 'temp',     decimals: 0 },
    { label: 'CO₂',         field: 'CO2',      decimals: 0 },
    { label: 'Humidity',    field: 'rH',       decimals: 0 },
    { label: 'VOC Index',   field: 'VOC',      decimals: 0 },
    { label: 'PM2.5',       field: 'pmass25',  decimals: 1 },
    { label: 'NOx Index',   field: 'NOx',      decimals: 0 },
    { label: 'HCHO',        field: 'HCHO',     decimals: 1 },
    { label: 'Dew Point',   field: 'indoorTd', decimals: 0 },
  ];

  let overlayLocations: string[] = [];
  let overlayMetrics: (keyof NormalizedSensorData)[] = [];
  let overlayMetricsRight: (keyof NormalizedSensorData)[] = [];
  let overlaySeries: { data: { x: number; y: number }[]; color: string; label: string; axis?: 'left' | 'right'; decimals?: number }[] = [];
  let overlayLoading = false;
  let overlayError: string | null = null;

  function toggleOverlayLocation(loc: string) {
    overlayLocations = overlayLocations.includes(loc)
      ? overlayLocations.filter(l => l !== loc)
      : [...overlayLocations, loc];
  }

  function toggleOverlayMetric(field: keyof NormalizedSensorData) {
    overlayMetrics = overlayMetrics.includes(field)
      ? overlayMetrics.filter(f => f !== field)
      : [...overlayMetrics, field];
  }

  function toggleOverlayMetricRight(field: keyof NormalizedSensorData) {
    overlayMetricsRight = overlayMetricsRight.includes(field)
      ? overlayMetricsRight.filter(f => f !== field)
      : [...overlayMetricsRight, field];
  }

  function overlayLabel(loc: string, metricLabel: string): string {
    const name = locationLabel(loc);
    if (overlayLocations.length > 1 && overlayMetrics.length > 1) return `${name} · ${metricLabel}`;
    if (overlayLocations.length > 1) return name;
    return metricLabel;
  }

  async function generateOverlay() {
    if (overlayLocations.length === 0 || overlayMetrics.length === 0) return;
    overlayLoading = true;
    overlayError = null;
    overlaySeries = [];
    try {
      const results = await Promise.all(
        overlayLocations.map(async loc => {
          const url = new URL(getApiUrl('sensor-data'), window.location.origin);
          url.searchParams.append('location', loc);
          if (startDate) url.searchParams.append('startDate', `${startDate}T${startHour.toString().padStart(2, '0')}:00:00`);
          if (endDate)   url.searchParams.append('endDate',   `${endDate}T${endHour.toString().padStart(2, '0')}:59:59`);
          const res = await fetch(url);
          if (!res.ok) throw new Error(`HTTP ${res.status} for location ${loc}`);
          return { loc, data: ((await res.json()) ?? []) as NormalizedSensorData[] };
        })
      );
      let colorIdx = 0;
      const built: typeof overlaySeries = [];
      for (const { loc, data } of results) {
        for (const field of overlayMetrics) {
          const metricDef = OVERLAY_METRICS.find(m => m.field === field)!;
          built.push({
            data: createTimeSeriesData(data, field),
            color: OVERLAY_COLORS[colorIdx % OVERLAY_COLORS.length],
            label: overlayLabel(loc, metricDef.label),
            axis: 'left',
            decimals: metricDef.decimals
          });
          colorIdx++;
        }
        for (const field of overlayMetricsRight) {
          const metricDef = OVERLAY_METRICS.find(m => m.field === field)!;
          built.push({
            data: createTimeSeriesData(data, field),
            color: OVERLAY_COLORS[colorIdx % OVERLAY_COLORS.length],
            label: overlayLabel(loc, metricDef.label),
            axis: 'right',
            decimals: metricDef.decimals
          });
          colorIdx++;
        }
      }
      overlaySeries = built;
    } catch (err) {
      overlayError = err instanceof Error ? err.message : 'Unknown error';
    } finally {
      overlayLoading = false;
    }
  }

  // Initial load
  onMount(() => {
    setDefaultDateRange();
    // Names are cosmetic — load in the background, never block the page.
    fetch(getApiUrl('location-names'))
      .then(r => r.ok ? r.json() : {})
      .then(names => { locationNames = names ?? {}; })
      .catch(() => {});
    // fetchLocations must finish before fetchData so selectedLocation is set
    // to the first location.
    fetchLocations().then(() => fetchData());
    fetchStationHealth();
    lastRefresh = Date.now();

    // Live refresh. Browsers slow timers in hidden tabs, so also refresh
    // right away when the tab comes back into view after a missed cycle.
    const timer = setInterval(refresh, REFRESH_MS);
    const onVisible = () => {
      if (!document.hidden && Date.now() - lastRefresh >= REFRESH_MS) refresh();
    };
    document.addEventListener('visibilitychange', onVisible);
    return () => {
      clearInterval(timer);
      document.removeEventListener('visibilitychange', onVisible);
    };
  });
</script>

<main class="min-h-screen bg-slate-50">

  <!-- Header -->
  <header class="bg-gradient-to-r from-slate-800 to-slate-700 shadow-lg">
    <div class="max-w-6xl mx-auto px-6 py-5 flex items-center justify-between">
      <div>
        <h1 class="text-2xl font-bold text-white tracking-tight">IAQ Dashboard</h1>
        <p class="text-slate-400 text-sm mt-0.5">Indoor Air Quality Monitoring</p>
      </div>
      {#if !loading && sensorData.length > 0}
        <div class="text-right hidden sm:block">
          <div class="text-white font-semibold">{sensorData.length.toLocaleString()} readings</div>
          <div class="text-slate-400 text-sm">
            {new Date(sensorData[sensorData.length - 1].recTime).toLocaleDateString()} – {new Date(sensorData[0].recTime).toLocaleDateString()}
          </div>
        </div>
      {/if}
    </div>
  </header>

  <div class="max-w-6xl mx-auto px-4 sm:px-6 py-6 space-y-4">

    <!-- Location selector -->
    {#if availableLocations.length > 0}
      <div class="bg-white rounded-xl shadow-sm border border-gray-100 p-5">
        <h2 class="text-xs font-semibold text-gray-400 uppercase tracking-wider mb-3">Sensor Location</h2>
        <div class="flex flex-wrap gap-2">
          {#each availableLocations as loc}
            {#if editingLocation === loc.location}
              <div class="flex items-center gap-1">
                <input
                  use:focusOnMount
                  bind:value={editingValue}
                  placeholder="Location {loc.location}"
                  on:keydown={e => { if (e.key === 'Enter') saveEdit(); if (e.key === 'Escape') editingLocation = null; }}
                  on:blur={saveEdit}
                  class="px-3 py-1 rounded-full text-sm border border-slate-400 focus:outline-none focus:ring-2 focus:ring-slate-500 w-36"
                />
              </div>
            {:else}
              <div class="group flex items-center gap-0.5">
                <button
                  on:click={() => { selectedLocation = loc.location; fetchData(); }}
                  class="px-4 py-1.5 rounded-full text-sm font-medium transition-colors {selectedLocation === loc.location ? 'bg-slate-700 text-white' : 'bg-gray-100 text-gray-600 hover:bg-gray-200'}"
                >
                  {locationLabel(loc.location)}
                </button>
                <button
                  on:click|stopPropagation={() => startEdit(loc.location)}
                  title="Rename"
                  class="opacity-0 group-hover:opacity-100 transition-opacity p-1 rounded-full text-gray-400 hover:text-gray-600 hover:bg-gray-100"
                >
                  <svg xmlns="http://www.w3.org/2000/svg" class="w-3.5 h-3.5" viewBox="0 0 20 20" fill="currentColor">
                    <path d="M13.586 3.586a2 2 0 112.828 2.828l-.793.793-2.828-2.828.793-.793zM11.379 5.793L3 14.172V17h2.828l8.38-8.379-2.83-2.828z" />
                  </svg>
                </button>
              </div>
            {/if}
          {/each}
        </div>
      </div>
    {/if}

    <!-- Station health -->
    {#if stationHealth.length > 0}
      <div class="bg-white rounded-xl shadow-sm border border-gray-100 p-5">
        <h2 class="text-xs font-semibold text-gray-400 uppercase tracking-wider mb-3">Station Health</h2>
        <div class="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-3 gap-3">
          {#each stationHealth as s (s.location)}
            <div class="rounded-lg border border-gray-100 p-3">
              <div class="flex items-baseline justify-between gap-2">
                <span class="font-medium text-gray-700 truncate">{locationLabel(s.location)}</span>
                {#if s.firmware}<span class="text-xs text-gray-400 shrink-0">{s.firmware}</span>{/if}
              </div>
              <dl class="mt-2 space-y-1 text-xs">
                {#each healthRows(s) as row (row.label)}
                  <div class="flex items-center gap-2">
                    <span class="w-2 h-2 rounded-full shrink-0 {LEVEL_STYLE[row.level].dot}"></span>
                    <dt class="text-gray-500 w-24 shrink-0">{row.label}</dt>
                    <dd class="{LEVEL_STYLE[row.level].text} min-w-0">{row.text}</dd>
                  </div>
                {/each}
              </dl>
              {#if isOffline(s) && s.minutesSinceLast !== null}
                <p class="text-xs text-gray-400 mt-2">Sensor statuses are from the last report.</p>
              {/if}
            </div>
          {/each}
        </div>
      </div>
    {/if}

    <!-- Time range filter -->
    <div class="bg-white rounded-xl shadow-sm border border-gray-100 p-5">
      <h2 class="text-xs font-semibold text-gray-400 uppercase tracking-wider mb-4">Time Range</h2>
      <div class="grid grid-cols-1 sm:grid-cols-2 gap-6 mb-4">
        <div>
          <div class="text-sm font-medium text-gray-600 mb-2">From</div>
          <div class="flex flex-wrap gap-3">
            <div class="flex items-center gap-2">
              <label for="start-date" class="text-sm text-gray-400">Date</label>
              <input type="date" id="start-date" bind:value={startDate} on:change={handleDateChange}
                class="border border-gray-200 rounded-lg px-3 py-1.5 text-sm focus:outline-none focus:ring-2 focus:ring-slate-400" />
            </div>
            <div class="flex items-center gap-2">
              <label for="start-hour" class="text-sm text-gray-400">Hour</label>
              <select id="start-hour" bind:value={startHour} on:change={handleDateChange}
                class="border border-gray-200 rounded-lg px-3 py-1.5 text-sm focus:outline-none focus:ring-2 focus:ring-slate-400">
                {#each hours as hour}
                  <option value={hour.value}>{hour.label}</option>
                {/each}
              </select>
            </div>
          </div>
        </div>
        <div>
          <div class="text-sm font-medium text-gray-600 mb-2">To</div>
          <div class="flex flex-wrap gap-3">
            <div class="flex items-center gap-2">
              <label for="end-date" class="text-sm text-gray-400">Date</label>
              <input type="date" id="end-date" bind:value={endDate} on:change={handleDateChange}
                class="border border-gray-200 rounded-lg px-3 py-1.5 text-sm focus:outline-none focus:ring-2 focus:ring-slate-400" />
            </div>
            <div class="flex items-center gap-2">
              <label for="end-hour" class="text-sm text-gray-400">Hour</label>
              <select id="end-hour" bind:value={endHour} on:change={handleDateChange}
                class="border border-gray-200 rounded-lg px-3 py-1.5 text-sm focus:outline-none focus:ring-2 focus:ring-slate-400">
                {#each hours as hour}
                  <option value={hour.value}>{hour.label}</option>
                {/each}
              </select>
            </div>
          </div>
        </div>
      </div>
      <div class="flex flex-wrap gap-2 pt-3 border-t border-gray-100">
        <button on:click={resetDateFilters}
          class="px-3 py-1.5 rounded-lg text-sm font-medium bg-gray-100 text-gray-600 hover:bg-gray-200 transition-colors">
          Reset
        </button>
        <button on:click={() => selectPreset(30 * 24)}
          class="px-3 py-1.5 rounded-lg text-sm font-medium bg-slate-700 text-white hover:bg-slate-800 transition-colors">
          Last Month
        </button>
        <button on:click={() => selectPreset(7 * 24)}
          class="px-3 py-1.5 rounded-lg text-sm font-medium bg-slate-700 text-white hover:bg-slate-800 transition-colors">
          Last Week
        </button>
        <button on:click={() => selectPreset(24)}
          class="px-3 py-1.5 rounded-lg text-sm font-medium bg-slate-600 text-white hover:bg-slate-700 transition-colors">
          Last 24 Hours
        </button>
        <button on:click={() => selectPreset(6)}
          class="px-3 py-1.5 rounded-lg text-sm font-medium bg-slate-600 text-white hover:bg-slate-700 transition-colors">
          Last 6 Hours
        </button>
        <button on:click={() => selectPreset(1)}
          class="px-3 py-1.5 rounded-lg text-sm font-medium bg-slate-500 text-white hover:bg-slate-600 transition-colors">
          Last Hour
        </button>
      </div>
    </div>

    <!-- Loading / error / empty states -->
    {#if loading}
      <div class="flex flex-col items-center justify-center h-48 bg-white rounded-xl shadow-sm border border-gray-100">
        <div class="spinner mb-3"></div>
        <p class="text-gray-400 text-sm">Loading sensor data…</p>
      </div>
    {:else if error}
      <div class="bg-red-50 border border-red-200 text-red-700 p-5 rounded-xl">
        <p class="font-semibold mb-1">Connection error</p>
        <p class="text-sm">{error}</p>
      </div>
    {:else if sensorData.length === 0}
      <div class="bg-amber-50 border border-amber-200 text-amber-700 p-5 rounded-xl">
        <p class="font-semibold">No data</p>
        {#if availableLocations.length === 0}
          <p class="text-sm mt-1">No stations have reported yet. Stations appear here after their first report.</p>
        {:else}
          <p class="text-sm mt-1">No readings found for the selected filters.</p>
        {/if}
      </div>
    {:else}

      <!-- Summary bar -->
      <p class="text-sm text-gray-400 px-1">
        Showing <span class="font-medium text-gray-600">{sensorData.length.toLocaleString()}</span> readings
        · <span class="font-medium text-gray-600">{new Date(sensorData[sensorData.length - 1].recTime).toLocaleString()}</span>
        → <span class="font-medium text-gray-600">{new Date(sensorData[0].recTime).toLocaleString()}</span>
        {#if lastUpdated}
          ·
          {#if refreshFailed}
            <span class="text-amber-600">Couldn't update; showing data from {lastUpdated.toLocaleTimeString([], { hour: 'numeric', minute: '2-digit' })}</span>
          {:else if rangeLive}
            <span>Updated {lastUpdated.toLocaleTimeString([], { hour: 'numeric', minute: '2-digit' })}, refreshes every 2 min</span>
          {:else}
            <span>Fixed range, not refreshing</span>
          {/if}
        {/if}
      </p>

      <!-- Chart cards -->
      <div class="space-y-4">

        <section class="chart-card" style="border-left-color: #ef4444">
          <div class="card-header">
            <h2 class="card-title">Temperature</h2>
          </div>
          <LineChart data={tempChart} label="Temperature (°F)" color="#ef4444"
            yAxisOptions={tempAxisOptions} xAxisOptions={xAxisOptions} />
        </section>

        <section class="chart-card" style="border-left-color: #10b981">
          <div class="card-header">
            <h2 class="card-title">CO₂</h2>
            <p class="card-note">Warning from 1,000 ppm, when ventilation should be increased; very high above 2,000 ppm (German Environment Agency indoor guide values). Health Canada's limit for homes is also 1,000 ppm, averaged over 24 hours.</p>
          </div>
          <LineChart data={co2Chart} label="CO2 (ppm)" color="#10b981"
            thresholds={GUIDELINES.co2} unit="ppm"
            yAxisOptions={co2AxisOptions} xAxisOptions={xAxisOptions} />
        </section>

        <section class="chart-card" style="border-left-color: #3b82f6">
          <div class="card-header">
            <h2 class="card-title">Humidity</h2>
          </div>
          <LineChart data={humidityChart} label="Humidity (%)" color="#3b82f6"
            xAxisOptions={xAxisOptions} />
        </section>

        <section class="chart-card" style="border-left-color: #8b5cf6">
          <div class="card-header">
            <h2 class="card-title">VOC</h2>
            <p class="card-note">Volatile Organic Compound index (1–500). Relative to the sensor's 24-hour rolling baseline — a value of 100 represents the average VOC level. Values above 100 indicate more VOCs than the recent average (e.g., cooking, cleaning); values below 100 indicate fewer VOCs (e.g., fresh air from an open window or air purifier).</p>
          </div>
          <LineChart data={vocChart} label="VOC Index" color="#8b5cf6"
            yAxisOptions={vocAxisOptions} xAxisOptions={xAxisOptions} />
        </section>

        <section class="chart-card" style="border-left-color: #f59e0b">
          <div class="card-header">
            <h2 class="card-title">Particulate Matter (PM2.5)</h2>
            <p class="card-note">Warning above 15 μg/m³ (WHO guideline) and very high above 35 μg/m³ (US EPA standard), both averaged over 24 hours. Short peaks from cooking or cleaning are normal.</p>
          </div>
          <LineChart data={pmassChart} label="PM2.5 (μg/m³)" color="#f59e0b"
            thresholds={GUIDELINES.pm25} unit="μg/m³" decimals={1}
            yAxisOptions={pmAxisOptions} xAxisOptions={xAxisOptions} />
        </section>

        <section class="chart-card" style="border-left-color: #f97316">
          <div class="card-header">
            <h2 class="card-title">NOx</h2>
            <p class="card-note">Nitrogen Oxides index (1–500). Relative to the sensor's 24-hour rolling baseline — a value of 1 means (nearly) no NOx detected. Values above 1 indicate elevated oxidising gases; spikes above 20 are typical of gas cooking or similar sources.</p>
          </div>
          <LineChart data={noxChart} label="NOx Index" color="#f97316"
            yAxisOptions={noxAxisOptions} xAxisOptions={xAxisOptions} />
        </section>

        <section class="chart-card" style="border-left-color: #06b6d4">
          <div class="card-header">
            <h2 class="card-title">Formaldehyde (HCHO)</h2>
            <p class="card-note">Warning above 40 ppb averaged over 8 hours, very high above 100 ppb averaged over 1 hour (Health Canada residential guideline).</p>
          </div>
          <LineChart data={hchoChart} label="HCHO (ppb)" color="#06b6d4"
            thresholds={GUIDELINES.hcho} unit="ppb" decimals={1}
            yAxisOptions={hchoAxisOptions} xAxisOptions={xAxisOptions} />
        </section>

        <section class="chart-card" style="border-left-color: #64748b">
          <div class="card-header">
            <h2 class="card-title">Dew Point</h2>
          </div>
          <LineChart data={dpChart} label="Dew Point (°F)" color="#64748b"
            yAxisOptions={dpAxisOptions} xAxisOptions={xAxisOptions} />
        </section>

      </div>
    {/if}

    <!-- ── Custom Overlay Chart ─────────────────────────────────────────── -->
    {#if availableLocations.length > 0}
      <div class="bg-white rounded-xl shadow-sm border border-gray-100 p-5">
        <h2 class="text-xs font-semibold text-gray-400 uppercase tracking-wider mb-1">Custom Overlay Chart</h2>
        <p class="text-xs text-gray-400 mb-5">Combine any locations and metrics on one chart. Works best when selected metrics share similar value ranges.</p>

        <div class="mb-4">
          <div class="text-sm font-medium text-gray-600 mb-2">Locations</div>
          <div class="flex flex-wrap gap-2">
            {#each availableLocations as loc}
              <button
                on:click={() => toggleOverlayLocation(loc.location)}
                class="px-4 py-1.5 rounded-full text-sm font-medium transition-colors {overlayLocations.includes(loc.location) ? 'bg-slate-700 text-white' : 'bg-gray-100 text-gray-600 hover:bg-gray-200'}"
              >
                {locationLabel(loc.location)}
              </button>
            {/each}
          </div>
        </div>

        <div class="mb-4">
          <div class="text-sm font-medium text-gray-600 mb-2">Metrics — Left Axis</div>
          <div class="flex flex-wrap gap-2">
            {#each OVERLAY_METRICS as m}
              <button
                on:click={() => toggleOverlayMetric(m.field)}
                class="px-4 py-1.5 rounded-full text-sm font-medium transition-colors {overlayMetrics.includes(m.field) ? 'bg-indigo-600 text-white' : 'bg-gray-100 text-gray-600 hover:bg-gray-200'}"
              >
                {m.label}
              </button>
            {/each}
          </div>
        </div>

        <div class="mb-5">
          <div class="text-sm font-medium text-gray-600 mb-1">Metrics — Right Axis <span class="text-xs font-normal text-gray-400">optional · use for metrics with a different scale</span></div>
          <div class="flex flex-wrap gap-2">
            {#each OVERLAY_METRICS as m}
              <button
                on:click={() => toggleOverlayMetricRight(m.field)}
                class="px-4 py-1.5 rounded-full text-sm font-medium transition-colors {overlayMetricsRight.includes(m.field) ? 'bg-orange-500 text-white' : 'bg-gray-100 text-gray-600 hover:bg-gray-200'}"
              >
                {m.label}
              </button>
            {/each}
          </div>
        </div>

        <div class="flex items-center gap-3 pb-5 border-b border-gray-100">
          <button
            on:click={generateOverlay}
            disabled={overlayLocations.length === 0 || (overlayMetrics.length === 0 && overlayMetricsRight.length === 0) || overlayLoading}
            class="px-5 py-2 rounded-lg text-sm font-semibold bg-slate-700 text-white hover:bg-slate-800 transition-colors disabled:opacity-40 disabled:cursor-not-allowed"
          >
            {overlayLoading ? 'Loading…' : 'Generate Chart'}
          </button>
          <span class="text-xs text-gray-400">
            {#if overlayLocations.length === 0 || (overlayMetrics.length === 0 && overlayMetricsRight.length === 0)}
              Select at least one location and one metric
            {:else}
              {overlayLocations.length} location{overlayLocations.length > 1 ? 's' : ''}
              · {overlayMetrics.length + overlayMetricsRight.length} metric{(overlayMetrics.length + overlayMetricsRight.length) > 1 ? 's' : ''}
              · {overlayLocations.length * (overlayMetrics.length + overlayMetricsRight.length)} series
            {/if}
          </span>
        </div>

        <div class="mt-5">
          {#if overlayLoading}
            <div class="flex flex-col items-center justify-center h-48">
              <div class="spinner mb-3"></div>
              <p class="text-gray-400 text-sm">Fetching overlay data…</p>
            </div>
          {:else if overlayError}
            <div class="bg-red-50 border border-red-200 text-red-700 p-4 rounded-lg text-sm">
              <span class="font-semibold">Error:</span> {overlayError}
            </div>
          {:else if overlaySeries.length > 0}
            <MultiLineChart series={overlaySeries} height={380} />
          {:else}
            <div class="flex items-center justify-center h-32 bg-gray-50 rounded-lg border border-dashed border-gray-200">
              <p class="text-gray-400 text-sm">Your overlay chart will appear here</p>
            </div>
          {/if}
        </div>
      </div>
    {/if}

  </div>
</main>

<style>
  :global(body) {
    background-color: #f8fafc;
    color: #111827;
  }

  .chart-card {
    background: white;
    border-radius: 0.75rem;
    box-shadow: 0 1px 3px rgba(0,0,0,0.06), 0 1px 2px rgba(0,0,0,0.04);
    border: 1px solid #f1f5f9;
    border-left: 4px solid #cbd5e1;
    overflow: hidden;
    padding: 1.25rem 1.25rem 0.75rem;
  }

  .card-header {
    margin-bottom: 0.5rem;
  }

  .card-title {
    font-size: 0.9375rem;
    font-weight: 600;
    color: #374151;
  }

  .card-note {
    font-size: 0.75rem;
    color: #9ca3af;
    margin-top: 0.25rem;
    line-height: 1.5;
  }

  .spinner {
    width: 2rem;
    height: 2rem;
    border: 3px solid #e2e8f0;
    border-top-color: #475569;
    border-radius: 50%;
    animation: spin 0.8s linear infinite;
  }

  @keyframes spin {
    to { transform: rotate(360deg); }
  }
</style>

