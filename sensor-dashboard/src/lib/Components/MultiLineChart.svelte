<script lang="ts">
  import { VisXYContainer, VisLine, VisAxis, VisTooltip, VisCrosshair } from '@unovis/svelte';

  type DataRecord = { x: number; y: number };

  export type SeriesConfig = {
    data: DataRecord[];
    color: string;
    label: string;
  };

  export let series: SeriesConfig[] = [];
  export let height: number = 380;

  const x = (d: DataRecord) => d.x;
  const y = (d: DataRecord) => d.y;

  $: activeSeries = series.filter(s => s.data.length > 0);

  // Container uses the densest series for the x-scale and crosshair snapping
  $: containerData = activeSeries.reduce(
    (best, s) => s.data.length > best.data.length ? s : best,
    activeSeries[0] ?? { data: [], color: '', label: '' }
  ).data;

  // Crosshair tooltip: nearest-neighbour lookup into every series at the hovered x
  $: crosshairTemplate = (d: DataRecord) => {
    const time = new Date(d.x).toLocaleString(undefined, {
      month: 'short', day: 'numeric', hour: '2-digit', minute: '2-digit'
    });
    const rows = activeSeries.map(s => {
      const nearest = s.data.reduce((best, cur) =>
        Math.abs(cur.x - d.x) < Math.abs(best.x - d.x) ? cur : best,
        s.data[0]
      );
      if (!nearest) return '';
      return `<div style="display:flex;align-items:center;gap:6px;margin-top:3px">
        <span style="display:inline-block;width:10px;height:10px;border-radius:2px;background:${s.color};flex-shrink:0"></span>
        <span style="font-size:0.8125rem;color:#374151">${s.label}: <strong>${nearest.y.toFixed(2)}</strong></span>
      </div>`;
    }).join('');
    return `<div style="padding:8px 10px;font-family:sans-serif;min-width:180px">
      <div style="font-weight:600;font-size:0.8125rem;margin-bottom:2px;color:#374151">${time}</div>
      ${rows}
    </div>`;
  };

  const xTickFormat = (v: number) =>
    new Date(v).toLocaleString(undefined, { month: 'short', day: 'numeric', hour: '2-digit' });
</script>

<div class="multi-chart">
  {#if activeSeries.length === 0}
    <div class="empty">No data to display</div>
  {:else}
    <VisXYContainer data={containerData} {height}>
      {#each activeSeries as s}
        <VisLine
          data={s.data}
          {x}
          {y}
          curveType="monotoneX"
          lineWidth={2}
          color={s.color}
          highlightOnHover={true}
        />
      {/each}
      <VisAxis type="x" position="bottom" label="Time" numTicks={6} gridLine={true} tickFormat={xTickFormat} />
      <VisAxis type="y" position="left" numTicks={5} gridLine={true} />
      <VisCrosshair {x} {y} color={activeSeries[0]?.color ?? '#1d4ed8'} template={crosshairTemplate} />
      <VisTooltip />
    </VisXYContainer>

    <div class="legend">
      {#each activeSeries as s}
        <div class="legend-item">
          <span class="swatch" style="background:{s.color}"></span>
          <span class="legend-label">{s.label}</span>
        </div>
      {/each}
    </div>
  {/if}
</div>

<style>
  .multi-chart { position: relative; }

  .empty {
    display: flex;
    align-items: center;
    justify-content: center;
    height: 200px;
    color: #9ca3af;
    font-size: 0.875rem;
  }

  .legend {
    display: flex;
    flex-wrap: wrap;
    justify-content: center;
    gap: 6px 16px;
    margin-top: 10px;
  }

  .legend-item {
    display: flex;
    align-items: center;
    gap: 5px;
  }

  .swatch {
    display: inline-block;
    width: 12px;
    height: 12px;
    border-radius: 2px;
    flex-shrink: 0;
  }

  .legend-label {
    font-size: 0.8125rem;
    color: #4b5563;
  }
</style>
