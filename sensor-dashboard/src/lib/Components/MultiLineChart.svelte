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

  // Join all series onto a shared x-grid: { x, y0, y1, y2, ... }
  // VisLine per series uses y = d => d[`y${i}`]; NaN renders as a gap.
  type JoinedRecord = { x: number } & Record<string, number>;

  $: joinedData = (() => {
    if (series.length === 0) return [] as JoinedRecord[];
    const xSet = new Set<number>();
    for (const s of series) for (const pt of s.data) xSet.add(pt.x);
    const allX = Array.from(xSet).sort((a, b) => a - b);
    const maps = series.map(s => {
      const m = new Map<number, number>();
      for (const pt of s.data) m.set(pt.x, pt.y);
      return m;
    });
    return allX.map(x => {
      const rec: JoinedRecord = { x };
      maps.forEach((m, i) => { rec[`y${i}`] = m.has(x) ? m.get(x)! : NaN; });
      return rec;
    });
  })();

  const x = (d: JoinedRecord) => d.x;

  // Stable accessor array — avoids Unovis re-renders from new function refs each tick
  $: yAccessors = series.map((_, i) => (d: JoinedRecord) => d[`y${i}`]);

  $: crosshairTemplate = (d: JoinedRecord) => {
    const time = new Date(d.x).toLocaleString(undefined, {
      month: 'short', day: 'numeric', hour: '2-digit', minute: '2-digit'
    });
    const rows = series.map((s, i) => {
      const val = d[`y${i}`];
      if (isNaN(val)) return '';
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
  {#if joinedData.length === 0}
    <div class="empty">No data to display</div>
  {:else}
    <VisXYContainer data={joinedData} {height}>
      {#each series as s, i}
        <VisLine
          {x}
          y={yAccessors[i]}
          curveType="monotoneX"
          lineWidth={2}
          color={s.color}
          highlightOnHover={true}
        />
      {/each}
      <VisAxis type="x" position="bottom" label="Time" numTicks={6} gridLine={true} tickFormat={xTickFormat} />
      <VisAxis type="y" position="left" numTicks={5} gridLine={true} />
      <VisCrosshair {x} y={yAccessors[0]} color={series[0]?.color ?? '#1d4ed8'} template={crosshairTemplate} />
      <VisTooltip />
    </VisXYContainer>

    <div class="legend">
      {#each series as s}
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
