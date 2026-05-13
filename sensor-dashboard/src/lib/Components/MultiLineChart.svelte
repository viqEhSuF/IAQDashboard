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

  $: activeSeries = series.filter(s => s.data.length > 0);

  // Build joined data: one record per unique x, with y0/y1/... fields per series.
  // NaN where a series has no reading at that timestamp — VisLine renders NaN as a gap,
  // keeping each line continuous within its own data.
  type JoinedRecord = Record<string, number>;

  $: joinedData = (() => {
    if (activeSeries.length === 0) return [] as JoinedRecord[];
    const xSet = new Set<number>();
    for (const s of activeSeries) for (const pt of s.data) xSet.add(pt.x);
    const allX = Array.from(xSet).sort((a, b) => a - b);
    const maps = activeSeries.map(s => {
      const m = new Map<number, number>();
      for (const pt of s.data) m.set(pt.x, pt.y);
      return m;
    });
    return allX.map(xVal => {
      const rec: JoinedRecord = { x: xVal };
      maps.forEach((m, i) => { rec[`y${i}`] = m.get(xVal) ?? NaN; });
      return rec;
    });
  })();

  // Single VisLine with arrays of accessors + colors — the correct Unovis multi-line pattern.
  $: xAccessor = (d: JoinedRecord) => d.x;
  $: yAccessors = activeSeries.map((_, i) => (d: JoinedRecord) => d[`y${i}`]);
  $: colors = activeSeries.map(s => s.color);

  // Crosshair snaps to the densest series (index 0 after sort); tooltip shows all via lookup.
  $: crosshairY = yAccessors[0] ?? ((d: JoinedRecord) => d.y0);

  $: crosshairTemplate = (d: JoinedRecord) => {
    const time = new Date(d.x).toLocaleString(undefined, {
      month: 'short', day: 'numeric', hour: '2-digit', minute: '2-digit'
    });
    const rows = activeSeries.map((s, i) => {
      const val = d[`y${i}`];
      if (isNaN(val) || val === undefined) return '';
      return `<div style="display:flex;align-items:center;gap:6px;margin-top:3px">
        <span style="display:inline-block;width:10px;height:10px;border-radius:2px;background:${s.color};flex-shrink:0"></span>
        <span style="font-size:0.8125rem;color:#374151">${s.label}: <strong>${val.toFixed(2)}</strong></span>
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
    <VisXYContainer data={joinedData} {height}>
      <VisLine
        x={xAccessor}
        y={yAccessors}
        color={colors}
        curveType="monotoneX"
        lineWidth={2}
        highlightOnHover={true}
      />
      <VisAxis type="x" position="bottom" label="Time" numTicks={6} gridLine={true} tickFormat={xTickFormat} />
      <VisAxis type="y" position="left" numTicks={5} gridLine={true} />
      <VisCrosshair x={xAccessor} y={crosshairY} color={activeSeries[0]?.color ?? '#1d4ed8'} template={crosshairTemplate} />
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
