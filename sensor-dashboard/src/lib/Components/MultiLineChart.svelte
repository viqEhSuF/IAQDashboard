<script lang="ts">
  import { VisXYContainer, VisLine, VisAxis, VisTooltip, VisCrosshair } from '@unovis/svelte';

  type DataRecord = { x: number; y: number };

  export type SeriesConfig = {
    data: DataRecord[];
    color: string;
    label: string;
    axis?: 'left' | 'right';
  };

  export let series: SeriesConfig[] = [];
  export let height: number = 380;

  $: activeSeries = series.filter(s => s.data.length > 0);
  $: leftSeries   = activeSeries.filter(s => (s.axis ?? 'left') === 'left');
  $: rightSeries  = activeSeries.filter(s => s.axis === 'right');
  $: isDualAxis   = leftSeries.length > 0 && rightSeries.length > 0;

  function domainOf(list: SeriesConfig[]): [number, number] {
    let lo = Infinity, hi = -Infinity;
    for (const s of list)
      for (const pt of s.data)
        if (!isNaN(pt.y)) { lo = Math.min(lo, pt.y); hi = Math.max(hi, pt.y); }
    if (lo === Infinity) return [0, 1];
    if (lo === hi) return [lo - 1, hi + 1];
    const pad = (hi - lo) * 0.05;
    return [lo - pad, hi + pad];
  }

  $: leftDomain  = domainOf(isDualAxis ? leftSeries : activeSeries);
  $: rightDomain = isDualAxis ? domainOf(rightSeries) : leftDomain;

  const GAP_THRESHOLD_MS = 30 * 60 * 1000;
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

    const sortedXs = activeSeries.map(s =>
      s.data.map(pt => pt.x).sort((a, b) => a - b)
    );

    function interpolate(si: number, xVal: number): number {
      const m = maps[si];
      if (m.has(xVal)) return m.get(xVal)!;
      const xs = sortedXs[si];
      if (xs.length < 2) return NaN;
      let lo = 0, hi = xs.length;
      while (lo < hi) { const mid = (lo + hi) >> 1; if (xs[mid] < xVal) lo = mid + 1; else hi = mid; }
      const ai = lo, bi = lo - 1;
      if (bi < 0 || ai >= xs.length) return NaN;
      const x1 = xs[bi], x2 = xs[ai];
      if (x2 - x1 > GAP_THRESHOLD_MS) return NaN;
      return maps[si].get(x1)! + (maps[si].get(x2)! - maps[si].get(x1)!) * (xVal - x1) / (x2 - x1);
    }

    return allX.map(xVal => {
      const rec: JoinedRecord = { x: xVal };
      activeSeries.forEach((_, i) => { rec[`y${i}`] = interpolate(i, xVal); });
      return rec;
    });
  })();

  $: leftIndices  = activeSeries.map((_, i) => i).filter(i => (activeSeries[i].axis ?? 'left') === 'left');
  $: rightIndices = activeSeries.map((_, i) => i).filter(i => activeSeries[i].axis === 'right');

  $: xAccessor       = (d: JoinedRecord) => d.x;
  $: leftYAccessors  = leftIndices.map(i => (d: JoinedRecord) => d[`y${i}`]);
  $: rightYAccessors = rightIndices.map(i => (d: JoinedRecord) => d[`y${i}`]);
  $: leftColors      = leftIndices.map(i => activeSeries[i].color);
  $: rightColors     = rightIndices.map(i => activeSeries[i].color);

  $: allYAccessors = activeSeries.map((_, i) => (d: JoinedRecord) => d[`y${i}`]);
  $: allColors     = activeSeries.map(s => s.color);

  $: crosshairY = (isDualAxis ? leftYAccessors[0] : allYAccessors[0]) ?? ((d: JoinedRecord) => d.y0);

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

  // Shared fixed margins so both overlaid containers align perfectly.
  const dualMargin = { top: 10, right: 70, bottom: 50, left: 70 };
</script>

<div class="multi-chart">
  {#if activeSeries.length === 0}
    <div class="empty">No data to display</div>
  {:else if isDualAxis}
    <div class="dual-wrap">
      <!-- Base container: left-axis series, x-axis, left y-axis, crosshair -->
      <VisXYContainer data={joinedData} {height} yDomain={leftDomain} margin={dualMargin} autoMargin={false}>
        <VisLine x={xAccessor} y={leftYAccessors} color={leftColors}
          curveType="monotoneX" lineWidth={2} highlightOnHover={true} />
        <VisAxis type="x" position="bottom" label="Time" numTicks={6} gridLine={true} tickFormat={xTickFormat} />
        <VisAxis type="y" position="left" numTicks={5} gridLine={true} />
        <VisCrosshair x={xAccessor} y={crosshairY} color={activeSeries[0]?.color ?? '#1d4ed8'} template={crosshairTemplate} />
        <VisTooltip />
      </VisXYContainer>
      <!-- Overlay container: right-axis series and right y-axis only -->
      <div class="overlay">
        <VisXYContainer data={joinedData} {height} yDomain={rightDomain} margin={dualMargin} autoMargin={false}>
          <VisLine x={xAccessor} y={rightYAccessors} color={rightColors}
            curveType="monotoneX" lineWidth={2} />
          <VisAxis type="y" position="right" numTicks={5} gridLine={false} />
        </VisXYContainer>
      </div>
    </div>
  {:else}
    <VisXYContainer data={joinedData} {height}>
      <VisLine x={xAccessor} y={allYAccessors} color={allColors}
        curveType="monotoneX" lineWidth={2} highlightOnHover={true} />
      <VisAxis type="x" position="bottom" label="Time" numTicks={6} gridLine={true} tickFormat={xTickFormat} />
      <VisAxis type="y" position="left" numTicks={5} gridLine={true} />
      <VisCrosshair x={xAccessor} y={crosshairY} color={activeSeries[0]?.color ?? '#1d4ed8'} template={crosshairTemplate} />
      <VisTooltip />
    </VisXYContainer>
  {/if}

  <div class="legend">
    {#each activeSeries as s}
      <div class="legend-item">
        <span class="swatch" style="background:{s.color}"></span>
        <span class="legend-label">
          {s.label}{#if isDualAxis}<span class="axis-tag">{s.axis === 'right' ? 'R' : 'L'}</span>{/if}
        </span>
      </div>
    {/each}
  </div>
</div>

<style>
  .multi-chart { position: relative; }

  .dual-wrap { position: relative; }

  .overlay {
    position: absolute;
    top: 0;
    left: 0;
    width: 100%;
    pointer-events: none;
  }

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
    display: flex;
    align-items: center;
    gap: 4px;
  }

  .axis-tag {
    font-size: 0.65rem;
    font-weight: 600;
    background: #e5e7eb;
    color: #6b7280;
    border-radius: 3px;
    padding: 0 3px;
    line-height: 1.4;
  }
</style>
