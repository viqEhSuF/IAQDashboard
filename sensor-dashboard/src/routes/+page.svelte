<script lang="ts">
  import { onMount } from 'svelte';
  import LineChart from '$lib/Components/LineChart.svelte';
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
    minValue: 0,
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
  
  // Initial load
  onMount(() => {
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
            <button
              on:click={() => { selectedLocation = loc.location; fetchData(); }}
              class="px-4 py-1.5 rounded-full text-sm font-medium transition-colors {selectedLocation === loc.location ? 'bg-slate-700 text-white' : 'bg-gray-100 text-gray-600 hover:bg-gray-200'}"
            >
              Location {loc.location}
            </button>
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
            <p class="card-note">Volatile Organic Compound index (0–500). Normalised around 100 on a rolling basis — above 100 indicates higher VOC than the recent baseline, below 100 indicates cleaner air.</p>
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

