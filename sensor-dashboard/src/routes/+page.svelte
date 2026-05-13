<script lang="ts">
  import { onMount } from 'svelte';
  import LineChart from '$lib/Components/LineChart.svelte';
  import MultiLineChart from '$lib/Components/MultiLineChart.svelte';
  import type { NormalizedSensorData, LocationData } from '$lib/models';
  import { getApiUrl } from '$lib/config';
  
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

  // Persistent custom names — stored in localStorage as { "1": "Living Room", ... }
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
  
  // Set default date range to last 24 hours
  function setDefaultDateRange() {
    const now = new Date();
    const yesterday = new Date(now);
    yesterday.setDate(now.getDate() - 1);
    
    endDate = now.toISOString().split('T')[0];
    startDate = yesterday.toISOString().split('T')[0];
    startHour = 0;
    endHour = 23;
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
        availableLocations = await response.json();
      }
    } catch (err) {
      console.error('Error fetching locations:', err);
    }
  }

  // Fetch data with the current date range and selected location
  async function fetchData() {
    loading = true;
    error = null;

    try {
      // Build URL with date parameters - using the Go API endpoint
      const url = new URL(getApiUrl('sensor-data'), window.location.origin);

      // Add location filter if one is selected
      if (selectedLocation !== null) {
        url.searchParams.append('location', selectedLocation);
      }

      // Add date parameters with hour precision
      if (startDate) {
        const formattedStartDate = `${startDate}T${startHour.toString().padStart(2, '0')}:00:00`;
        url.searchParams.append('startDate', formattedStartDate);
      }

      if (endDate) {
        const formattedEndDate = `${endDate}T${endHour.toString().padStart(2, '0')}:59:59`;
        url.searchParams.append('endDate', formattedEndDate);
      }
      
      const response = await fetch(url);
      if (!response.ok) {
        throw new Error(`HTTP error: ${response.status}`);
      }
      
      // Get the normalized data from the API
      sensorData = await response.json();
      
      // Create chart datasets
      updateCharts();
      
      loading = false;
    } catch (err) {
      console.error('Error fetching data:', err);
      error = err instanceof Error ? err.message : 'Unknown error';
      loading = false;
    }
  }
  
  // Handle date input changes
  function handleDateChange() {
    fetchData();
  }
  
  // Reset date filters and fetch all data
  function resetDateFilters() {
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
  
  function createTimeSeriesData(data: NormalizedSensorData[], field: keyof NormalizedSensorData): DataRecord[] {
    return data
      .map(d => ({
        x: new Date(d.recTime).getTime(),
        y: Number(d[field])
      }))
      .sort((a, b) => a.x - b.x);
  }
  
  // ── Overlay chart ───────────────────────────────────────────────────────

  const OVERLAY_COLORS = [
    '#ef4444', '#3b82f6', '#10b981', '#f59e0b',
    '#8b5cf6', '#f97316', '#06b6d4', '#ec4899',
    '#84cc16', '#14b8a6', '#a78bfa', '#fb923c'
  ];

  const OVERLAY_METRICS: { label: string; field: keyof NormalizedSensorData }[] = [
    { label: 'Temperature', field: 'temp'     },
    { label: 'CO₂',         field: 'CO2'      },
    { label: 'Humidity',    field: 'rH'       },
    { label: 'VOC Index',   field: 'VOC'      },
    { label: 'PM2.5',       field: 'pmass25'  },
    { label: 'NOx Index',   field: 'NOx'      },
    { label: 'HCHO',        field: 'HCHO'     },
    { label: 'Dew Point',   field: 'indoorTd' },
  ];

  let overlayLocations: string[] = [];
  let overlayMetrics: (keyof NormalizedSensorData)[] = [];
  let overlaySeries: { data: { x: number; y: number }[]; color: string; label: string }[] = [];
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
          return { loc, data: await res.json() as NormalizedSensorData[] };
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
            label: overlayLabel(loc, metricDef.label)
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
  onMount(async () => {
    try {
      const res = await fetch(getApiUrl('location-names'));
      if (res.ok) locationNames = (await res.json()) ?? {};
    } catch { /* non-fatal — names fall back to "Location N" */ }
    setDefaultDateRange();
    fetchLocations();
    fetchData();
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
          <button
            on:click={() => { selectedLocation = null; fetchData(); }}
            class="px-4 py-1.5 rounded-full text-sm font-medium transition-colors {selectedLocation === null ? 'bg-slate-700 text-white' : 'bg-gray-100 text-gray-600 hover:bg-gray-200'}"
          >
            All Locations
          </button>
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
        <button on:click={() => { setDefaultDateRange(); handleDateChange(); }}
          class="px-3 py-1.5 rounded-lg text-sm font-medium bg-slate-700 text-white hover:bg-slate-800 transition-colors">
          Last 24 Hours
        </button>
        <button on:click={() => {
            const now = new Date();
            endDate = now.toISOString().split('T')[0]; endHour = now.getHours();
            startDate = endDate; startHour = Math.max(0, endHour - 6);
            handleDateChange();
          }}
          class="px-3 py-1.5 rounded-lg text-sm font-medium bg-slate-600 text-white hover:bg-slate-700 transition-colors">
          Last 6 Hours
        </button>
        <button on:click={() => {
            const now = new Date();
            endDate = now.toISOString().split('T')[0]; endHour = now.getHours();
            startDate = endDate; startHour = Math.max(0, endHour - 1);
            handleDateChange();
          }}
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
        <p class="text-sm mt-1">No readings found for the selected filters.</p>
      </div>
    {:else}

      <!-- Summary bar -->
      <p class="text-sm text-gray-400 px-1">
        Showing <span class="font-medium text-gray-600">{sensorData.length.toLocaleString()}</span> readings
        · <span class="font-medium text-gray-600">{new Date(sensorData[sensorData.length - 1].recTime).toLocaleString()}</span>
        → <span class="font-medium text-gray-600">{new Date(sensorData[0].recTime).toLocaleString()}</span>
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
          </div>
          <LineChart data={co2Chart} label="CO2 (ppm)" color="#10b981"
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
          </div>
          <LineChart data={pmassChart} label="PM2.5 (μg/m³)" color="#f59e0b"
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
          </div>
          <LineChart data={hchoChart} label="HCHO (ppb)" color="#06b6d4"
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

        <div class="mb-5">
          <div class="text-sm font-medium text-gray-600 mb-2">Metrics</div>
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

        <div class="flex items-center gap-3 pb-5 border-b border-gray-100">
          <button
            on:click={generateOverlay}
            disabled={overlayLocations.length === 0 || overlayMetrics.length === 0 || overlayLoading}
            class="px-5 py-2 rounded-lg text-sm font-semibold bg-slate-700 text-white hover:bg-slate-800 transition-colors disabled:opacity-40 disabled:cursor-not-allowed"
          >
            {overlayLoading ? 'Loading…' : 'Generate Chart'}
          </button>
          <span class="text-xs text-gray-400">
            {#if overlayLocations.length === 0 || overlayMetrics.length === 0}
              Select at least one location and one metric
            {:else}
              {overlayLocations.length} location{overlayLocations.length > 1 ? 's' : ''}
              · {overlayMetrics.length} metric{overlayMetrics.length > 1 ? 's' : ''}
              · {overlayLocations.length * overlayMetrics.length} series
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

