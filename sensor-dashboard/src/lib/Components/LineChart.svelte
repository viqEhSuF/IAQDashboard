<script lang="ts">
  import { VisXYContainer, VisLine, VisAxis, VisTooltip, VisCrosshair } from '@unovis/svelte';
  import { Line } from '@unovis/ts';
  
  // Define the data type expected
  type DataRecord = {
    x: number;
    y: number;
  };
  
  // Define axis options type
  type AxisOptions = {
    minValue?: number;
    maxValue?: number;
    tickFormat?: (tick: any) => string;
    numTicks?: number;
    gridLine?: boolean;
    tickLine?: boolean;
    tickTextColor?: string;
    tickTextFontSize?: string;
  };
  
  // A guideline drawn as a dashed horizontal line, e.g. "Elevated" at 1000 ppm
  type Threshold = {
    value: number;
    label: string;
    color: string;
  };

  // Accept data as a prop
  export let data: DataRecord[] = [];
  export let height: number = 300;
  export let label: string = '';
  export let color: string = '#1d4ed8';
  export let showLegend: boolean = true;
  // Decimal places in the hover tooltip
  export let decimals: number = 0;
  // Guideline lines, lowest first. The first is always drawn; each further one
  // is drawn once readings reach the one below it, so a chart of normal
  // readings isn't squeezed down to make room for a level far above them.
  export let thresholds: Threshold[] = [];
  export let unit: string = '';

  $: dataMax = data.length ? Math.max(...data.map(d => d.y)) : 0;
  $: shownThresholds = thresholds.filter((t, i) => i === 0 || dataMax >= thresholds[i - 1].value);
  // Charts with guidelines start at zero and leave room above the top line
  $: yDomain = thresholds.length
    ? [0, Math.max(dataMax, ...shownThresholds.map(t => t.value)) * 1.08] as [number, number]
    : undefined;
  
  // Axis configuration
  export let yAxisOptions: AxisOptions = {};
  export let xAxisOptions: AxisOptions = {};
  
  // Set default axis options based on label
  $: {
    // Default Y-axis options based on metric type
    if (label.includes('Temperature')) {
      yAxisOptions = {
        ...{
          minValue: undefined,
          maxValue: undefined,
          numTicks: 5,
          gridLine: true,
          tickFormat: (d) => `${d}°F`
        },
        ...yAxisOptions
      };
    } else if (label.includes('CO2')) {
      yAxisOptions = {
        ...{
          minValue: 0,
          maxValue: undefined,
          numTicks: 5,
          gridLine: true,
          tickFormat: (d) => `${d} ppm`
        },
        ...yAxisOptions
      };
    } else if (label.includes('Humidity')) {
      yAxisOptions = {
        ...{
          minValue: 0,
          maxValue: 100,
          numTicks: 5,
          gridLine: true,
          tickFormat: (d) => `${d}%`
        },
        ...yAxisOptions
      };
    } else if (label.includes('VOC')) {
      yAxisOptions = {
        ...{
          minValue: 1,
          maxValue: 500,
          numTicks: 5,
          gridLine: true,
          tickFormat: (d) => `${d}`
        },
        ...yAxisOptions
      };
    } else if (label.includes('PM2.5')) {
      yAxisOptions = {
        ...{
          minValue: 0,
          maxValue: undefined,
          numTicks: 5,
          gridLine: true,
          tickFormat: (d) => `${d} μg/m³`
        },
        ...yAxisOptions
      };
    } else if (label.includes('NOx Index')) {
      yAxisOptions = {
        ...{
          minValue: 1,
          maxValue: 500,
          numTicks: 5,
          gridLine: true,
          tickFormat: (d) => `${d}`
        },
        ...yAxisOptions
      };
    } else if (label.includes('HCHO')) {
      yAxisOptions = {
        ...{
          minValue: 0,
          maxValue: undefined,
          numTicks: 5,
          gridLine: true,
          tickFormat: (d) => `${d} ppb`
        },
        ...yAxisOptions
      };
    } else if (label.includes('Dew Point')) {
      yAxisOptions = {
        ...{
          minValue: undefined,
          maxValue: undefined,
          numTicks: 5,
          gridLine: true,
          tickFormat: (d) => `${d}°F`
        },
        ...yAxisOptions
      };
    }
    
    // Default X-axis options (time-based)
    xAxisOptions = {
      ...{
        numTicks: 5,
        gridLine: true,
        tickFormat: (d) => {
          const date = new Date(d);
          return date.toLocaleString(undefined, { 
            month: 'short', 
            day: 'numeric', 
            hour: '2-digit', 
            minute: '2-digit'
          });
        }
      },
      ...xAxisOptions
    };
  }
  
  // Define accessors
  const x = (d: DataRecord) => d.x;
  const y = (d: DataRecord) => d.y;
  
  // Format a raw y value with the correct unit for this chart
  function formatValue(y: number): string {
    const v = y.toFixed(decimals);
    if (label.includes('Temperature'))  return `${v}°F`;
    if (label.includes('CO2'))          return `${v} ppm`;
    if (label.includes('Humidity'))     return `${v}%`;
    if (label.includes('VOC Index'))    return v;
    if (label.includes('NOx Index'))    return v;
    if (label.includes('HCHO'))         return `${v} ppb`;
    if (label.includes('Dew Point'))    return `${v}°F`;
    if (label.includes('PM2.5'))        return `${v} μg/m³`;
    return v;
  }

  // The highest guideline a reading is at or above, if any
  function levelOf(y: number): Threshold | undefined {
    return [...thresholds].reverse().find(t => y >= t.value);
  }

  // Crosshair tooltip template — called with the snapped data point
  $: crosshairTemplate = (d: DataRecord) => {
    const level = levelOf(d.y);
    const levelLine = level
      ? `<div style="margin-top:2px;color:${level.color};font-weight:600;">${level.label} (${level.value.toLocaleString()}${unit ? ' ' + unit : ''} or more)</div>`
      : '';
    return `
    <div style="padding:8px;font-family:sans-serif;min-width:160px;">
      <div style="font-weight:600;margin-bottom:4px;">${new Date(d.x).toLocaleString()}</div>
      <div>${label}: <strong>${formatValue(d.y)}</strong></div>
      ${levelLine}
    </div>
  `;
  };
</script>

<div class="chart-container">
  <div style="height: {height}px; width: 100%;">
    {#if data.length === 0}
      <div class="flex justify-center items-center h-full">
        <p class="text-gray-500">No data available</p>
      </div>
    {:else}
      <!-- Rebuild the chart when its data changes: the Unovis Svelte container
           stores new data without redrawing (setData(data, true)), so a live
           refresh would otherwise keep showing the old line. -->
      {#key data}
      <VisXYContainer {data} height={height} {yDomain}>
        <!-- Guideline lines first, so the readings draw on top of them -->
        {#each shownThresholds as t (t.value)}
          <VisLine {x} y={() => t.value} color={t.color} lineWidth={1.5} lineDashArray={[6, 4]} />
        {/each}
        <VisLine
          {x}
          {y} 
          curveType="monotoneX"
          lineWidth={2}
          {color}
          highlightOnHover={true}
          attributes={{
            [Line.selectors.line]: {
              'data-testid': 'line-chart',
              'data-metric': label
            }
          }}
        />
        <VisAxis 
          position="bottom" 
          label="Time" 
          type="x"
          numTicks={xAxisOptions.numTicks}
          gridLine={xAxisOptions.gridLine}
          tickFormat={(x: number) => {
            const date = new Date(x);
            return date.toLocaleString(undefined, { 
              month: 'short', 
              day: 'numeric', 
              hour: '2-digit', 
            });
          }}
          tickTextColor={xAxisOptions.tickTextColor}
          tickTextFontSize={xAxisOptions.tickTextFontSize}
        />
        <VisAxis 
          position="left" 
          label={label}
          type="y"
          numTicks={yAxisOptions.numTicks}
          gridLine={yAxisOptions.gridLine}
          tickFormat={(d: number) =>
            decimals === 0 && !Number.isInteger(d) ? ''  // whole-number charts label whole ticks only
              : (yAxisOptions.tickFormat ? yAxisOptions.tickFormat(d) : `${d}`)}
          tickTextColor={yAxisOptions.tickTextColor}
          tickTextFontSize={yAxisOptions.tickTextFontSize}
        />
        <VisCrosshair {x} {y} color={color} template={crosshairTemplate} />
        <VisTooltip />
      </VisXYContainer>
      {/key}
    {/if}
  </div>
  
  {#if showLegend && label}
    <div class="legend-container">
      <div class="legend-item">
        <span class="legend-color" style="background-color: {color}"></span>
        <span class="legend-name">{label}</span>
      </div>
      {#each shownThresholds as t (t.value)}
        <div class="legend-item">
          <span class="legend-dash" style="border-top-color: {t.color}"></span>
          <span class="legend-name">{t.label} {t.value.toLocaleString()}{unit ? ` ${unit}` : ''}</span>
        </div>
      {/each}
    </div>
  {/if}
</div>

<style>
  .chart-container {
    position: relative;
  }
  
  .legend-container {
    display: flex;
    flex-wrap: wrap;
    justify-content: center;
    margin-top: 8px;
  }
  
  .legend-item {
    display: flex;
    align-items: center;
    margin: 2px 8px;
  }
  
  .legend-color {
    display: inline-block;
    width: 12px;
    height: 12px;
    border-radius: 2px;
    margin-right: 4px;
  }
  
  .legend-dash {
    display: inline-block;
    width: 18px;
    border-top: 2px dashed;
    margin-right: 4px;
  }

  .legend-name {
    font-size: 0.875rem;
    color: #4b5563;
  }
  
  :global(.unovis .vis-axis text) {
    fill: #4b5563;
  }
  
  :global(.unovis .vis-axis line) {
    stroke: #e5e7eb;
  }
  
  :global(.unovis .vis-axis path) {
    stroke: #d1d5db;
  }
  
  :global(.unovis .vis-tooltip) {
    background-color: rgba(255, 255, 255, 0.95);
    border: 1px solid #e5e7eb;
    border-radius: 4px;
    box-shadow: 0 2px 4px rgba(0, 0, 0, 0.1);
  }
</style>