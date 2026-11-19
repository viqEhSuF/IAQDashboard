# Converting a V1 site to V2, keeping its data

These scripts copy a V1 system's readings and station names into V2. They
work for both ways of converting a site:

- **New card:** a V2 card replaces the V1 card ("Converting a V1 IAQ Site to
  V2").
- **In place:** the V2 tables are added to the V1 Pi's database, the stations
  are reflashed one at a time, and the history is imported afterwards
  ("Converting an IAQ Pi to V2 in Place").

| File | Runs on | What it does |
|---|---|---|
| `export_v1.sh` | V1 Pi (old card) | Saves `IAQ_SEN55` and `location_names` to `~/v1_export_<date>_<time>.sql.gz` and lists the readings per station. Read-only. |
| `import_v1.sh` | V2 Pi (new card) | Checks the V2 database and time zone, loads the export into a staging database (`v1_import`), runs `import_v1.sql`. |
| `import_v1.sql` | (run by `import_v1.sh`) | Copies stations, names and readings into the V2 tables, records each station's V1 period in `v1_conversion`, and adds each station's starting temperature correction. |

## Short version

On the V1 Pi, right before the switch:

```bash
curl -fsSLO https://raw.githubusercontent.com/viqEhSuF/IAQDashboard/v2/migration/export_v1.sh
sudo bash export_v1.sh
```

Copy the export off the Pi, shut it down and swap in the V2 card. Then on the
V2 Pi, with its time zone set to the V1 system's:

```bash
sudo bash ~/IAQDashboard/migration/import_v1.sh ~/v1_export_YYYYMMDD_HHMM.sql.gz
```

Then reflash each station with the V2 firmware, keeping its V1 station number.

## How V1 data ends up in V2

- **Readings are shown as V1 recorded them.** V1 stations corrected
  temperature (°F ÷ `tempScale`) and humidity (× `rHscale`) in their firmware,
  so no V2 correction applies to readings from before the conversion.
- **Each station converts on its own.** A station's conversion time is one
  second after its own last V1 reading, so stations can be reflashed at
  different times, before or after the import. The times are kept in the
  `v1_conversion` table.
- **Temperature carries on without a step.** V2 firmware sends uncorrected
  readings, so each station gets a V2 temperature correction from its
  conversion time on that matches V1's: `slope = 1 / tempScale`,
  `offset = (32 / tempScale - 32) / 1.8` (about −1.4 °C, or −2.5 °F, at room
  temperature for 1.034). If the V1 sketches used a different `tempScale`,
  give it as `V1_TEMP_SCALE=...` after `sudo`. Check the correction against a
  reference afterwards.
- **Humidity carries on too.** V2 applies the standard humidity correction
  (×1.085, in `calibration_defaults`) from each station's conversion, close to
  V1's own ×1.116, so V2 reads about 3% lower than V1 did for the same air
  (50% becomes about 48.6%). If V1's factor turns out to be wrong, the import
  can divide it out of the history: `sudo V1_RH_UNSCALE=1.116 bash import_v1.sh ...`.
- **Standard corrections stay out of V1 history.** A station added to V2
  before its conversion (bench testing, for example) has its standard
  corrections moved to its conversion time, and its standard temperature
  correction is replaced by V1's.
- **Gaps stay gaps.** V1's "not available" codes (PM 6554, VOC 3277, RH 366,
  CO2 0, and similar) and other impossible values become empty readings.
  Humidity that V1's scaling pushed over 100% (up to 112%) is stored as 100.
- **Dew point is recalculated** by V2 from temperature and humidity; V1's
  stored dew point isn't copied.
- **Duplicates:** if V1 has two readings from one station in the same second,
  the second one is skipped.
- **Times are kept exactly**, including the repeated hour when clocks go back,
  because V1 stores them as `TIMESTAMP`. (If a V1 system stored local
  `DATETIME` values instead, the import still works, but the two copies of the
  repeated hour can't be told apart and one is skipped.)

## Running it again

`import_v1.sh` can be run again with the same export: readings already in V2
are skipped, and names and temperature corrections already set in V2 are
kept. To redo the V1 history with a different humidity setting, add
`REPLACE_HISTORY=1`. It deletes what V2 holds for each station up to its last
V1 reading, then imports again; V2 readings after that are kept:

```bash
sudo V1_RH_UNSCALE=1.116 REPLACE_HISTORY=1 bash ~/IAQDashboard/migration/import_v1.sh ~/v1_export_YYYYMMDD_HHMM.sql.gz
```

`REPLACE_HISTORY=1` also clears test readings that fall inside a station's V1
period, which the import otherwise stops on.

(A different `V1_TEMP_SCALE` on a re-run doesn't change corrections already
in place; change those as in step 7 of the guide.)

When the dashboard looks right, remove the staging copy:

```bash
sudo mariadb -e "DROP DATABASE v1_import"
```

Timing: about 45 seconds per 2 million readings (four stations over two
years) on a desktop. A Pi is slower; allow 10 to 20 minutes for a site with
years of data.
