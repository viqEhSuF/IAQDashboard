# IAQ Dashboard — User Manual

## Overview

The IAQ Dashboard displays real-time and historical indoor air quality readings from sensor stations placed around your home. It runs on a Raspberry Pi on your local network and is accessible from any device connected to the same Wi-Fi.

**To open the dashboard**, type the following into any browser:

```
http://iaq-dashboard.local/
```

If that does not work, use the Pi's IP address instead (e.g. `http://192.168.1.50/`).

---

## Page Layout

The page is organised into three areas from top to bottom:

1. **Sensor Location** — choose which station (or all stations) to view
2. **Time Range** — choose the period of data to display
3. **Charts** — one chart per air quality metric, plus a Custom Overlay Chart at the bottom

The header shows the total number of readings and the date range of the displayed data.

---

## Sensor Location

The **Sensor Location** panel appears near the top of the page.

- **All Locations** (default, highlighted in dark) — charts show combined data from every station
- **Individual location buttons** — clicking any location button restricts all charts to that station only. The selected button is highlighted.

### Renaming a Location

Location names can be customised so buttons read "Bedroom" instead of "Location 1". Names are stored on the server and appear the same across all browsers and devices.

1. Hover over a location button — a small pencil icon (✏) appears to its right
2. Click the pencil icon
3. An input field appears. Type the new name (e.g. `Bedroom`)
4. Press **Enter** or click anywhere else to save
5. Press **Escape** to cancel without saving
6. To revert to the default "Location N" label, clear the field and press **Enter**

---

## Time Range

Use the **Time Range** panel to control how far back the charts look.

### Date and Hour Selectors

- **From / To date pickers** — click to choose a start and end date
- **Hour dropdowns** — narrow the window to a specific hour within each date (00:00 – 23:00)

Any change to these fields immediately refreshes all charts.

### Quick-Select Buttons

For convenience, preset buttons replace the date fields in one click:

| Button | Data shown |
|---|---|
| **Reset** | All available data (no date filter applied) |
| **Last Month** | The past 30 days |
| **Last Week** | The past 7 days |
| **Last 24 Hours** | The past 24 hours *(loaded by default)* |
| **Last 6 Hours** | The past 6 hours |
| **Last Hour** | The past hour |

---

## Status Messages

| What you see | What it means |
|---|---|
| Spinning indicator | Data is loading — wait a moment |
| Red **"Connection error"** banner | The dashboard cannot reach the sensor service — check that the Raspberry Pi is powered on and connected to the network |
| Amber **"No data"** banner | No readings exist for the selected location and time window — try a longer range or switch to **All Locations** |

When data has loaded successfully, a summary line appears showing the total reading count and the exact start and end timestamps.

---

## Metric Charts

Eight charts are displayed, one per air quality metric. Each has a coloured left border for quick identification.

### How to Read a Chart

- **Hover** over the chart area to activate a crosshair that snaps to the nearest data point
- A **tooltip** shows the exact timestamp and value at that point
- A **legend** below each chart shows the metric name and colour

### Time Axis

The horizontal axis adapts to the selected time range:

- **Up to 24 hours** → shows hours and minutes (e.g. `01:30`)
- **Up to 3 days** → shows day and time (e.g. `Mon 01:30`)
- **Longer periods** → shows month and date (e.g. `May 13`)

### Metrics Reference

| Chart | What it measures | Unit | Typical range / notes |
|---|---|---|---|
| **Temperature** | Air temperature | °F | Y-axis scales to the data range |
| **CO₂** | Carbon dioxide | ppm | Outdoors ~420 ppm; above ~1000 ppm can cause stuffiness; above ~2000 ppm may affect concentration |
| **Humidity** | Relative humidity | % | Y-axis fixed 0–100%. Comfortable range is roughly 40–60% |
| **VOC** | Volatile Organic Compound index | 1–500 | Relative to the sensor's own 24-hour rolling average. **100 = typical for your space.** Values above 100 mean more VOCs than usual (cooking, cleaning products, fresh paint, adhesives); values below 100 mean fewer (open window, air purifier running). Y-axis fixed 1–500. |
| **PM2.5** | Fine particulate matter | μg/m³ | Particles smaller than 2.5 micrometres. Elevated by smoke, burning candles, dust, and cooking |
| **NOx** | Nitrogen Oxides index | 1–500 | Relative to the sensor's own 24-hour rolling average. **1 = effectively none detected.** Values above 1 indicate oxidising gases; spikes above ~20 are typical of gas cooking. Y-axis fixed 1–500. |
| **Formaldehyde (HCHO)** | Formaldehyde gas | ppb | Common in new furniture, flooring, and some cleaning products |
| **Dew Point** | Moisture content of air | °F | A practical comfort indicator. Below ~55 °F feels dry; above ~65 °F can feel humid and sticky |

---

## Custom Overlay Chart

The **Custom Overlay Chart**, found at the bottom of the page, lets you plot any combination of locations and metrics on a single chart — useful for comparing rooms or correlating different measurements. It supports a **dual Y-axis** mode so metrics with very different scales (such as Temperature and CO₂) can be compared without either line appearing flat.

### How to Use It

1. Under **Locations**, click one or more station buttons. A highlighted button is selected; click it again to deselect.
2. Under **Metrics — Left Axis**, click one or more metrics. These are shown in indigo when selected and will be plotted against the left Y-axis.
3. Under **Metrics — Right Axis** *(optional)*, click one or more metrics with a different scale. These are shown in orange when selected and will be plotted against the right Y-axis with its own independent scale.
4. Click **Generate Chart**.

The counter next to the button shows the total number of metrics selected and the total number of lines that will be drawn (locations × metrics).

### Single vs. Dual Y-Axis

- If you only select metrics from **Left Axis**, the chart uses a single Y-axis on the left.
- If you select metrics from **both** rows, the chart uses two independent Y-axes — left for the indigo metrics, right for the orange metrics. Each axis scales to fit its own data, so no series appears flattened.

### Reading the Overlay Chart

- Each line is drawn in a distinct colour
- The **legend** below the chart labels each line:
  - One location, multiple metrics → labels show the metric name
  - Multiple locations, one metric → labels show the location name
  - Multiple of both → labels show "Location · Metric"
- In dual Y-axis mode, each legend label has a small **L** or **R** tag showing which axis it belongs to
- **Hover** anywhere on the chart to see a tooltip listing all series values at that moment

### Tips

- Use the **Right Axis** for any metric whose values are on a completely different scale to the left-axis metrics. Good dual-axis combinations:
  - **Temperature** (left, °F) and **CO₂** (right, ppm)
  - **Humidity** (left, %) and **PM2.5** (right, μg/m³)
- Keep similar-scale metrics on the same axis for the clearest chart. Good single-axis combinations:
  - **VOC Index and NOx Index** (both 1–500)
  - **Temperature and Dew Point** (both °F)
  - **PM2.5 from multiple rooms** (same unit, comparable range)
- The time range and date filters set in the **Time Range** panel apply to the overlay chart as well — set your desired window before clicking Generate Chart.

---

## Common Tasks

**Compare two rooms side by side**
Select both locations in the Overlay Chart, choose one metric (e.g. CO₂), and click Generate Chart.

**Investigate a CO₂ spike**
Select the relevant room in the Location panel, click **Last 6 Hours**, and look at the CO₂ chart.

**Check overnight conditions**
Click **Last 24 Hours**, select the bedroom location, and review Temperature, Humidity, and CO₂.

**Find when VOC levels were highest this week**
Click **Last Week**, select a location, and look at the VOC chart. Hover the peaks to see the exact times.

**Compare Temperature and CO₂ in the same room**
In the Overlay Chart, select one location, add Temperature to Left Axis and CO₂ to Right Axis, then click Generate Chart. Both lines will be clearly readable on their own scales.
