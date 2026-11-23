package main

// CSV export for the dashboard's overlay section: chosen stations and
// metrics over a time range, as every reading or as averages over an
// interval. Rows are streamed to the browser as they are read, so a long
// export is never held in memory and has no row limit.

import (
	"database/sql"
	"encoding/csv"
	"fmt"
	"log"
	"net/http"
	"strconv"
	"strings"
	"time"
)

type exportMetric struct {
	column   string // column in sen55_display
	header   string // column heading in the file
	decimals int    // decimals in the file, as the dashboard shows them
}

// Keyed by the dashboard's field names
var exportMetrics = map[string]exportMetric{
	"temp":     {"temp", "Temperature (°F)", 1},
	"rH":       {"rH", "Humidity (%)", 1},
	"indoorTd": {"DP", "Dew point (°F)", 1},
	"CO2":      {"CO2", "CO2 (ppm)", 0},
	"VOC":      {"VOC", "VOC index", 0},
	"NOx":      {"NOx", "NOx index", 0},
	"pmass1":   {"pmass1", "PM1.0 (µg/m³)", 1},
	"pmass25":  {"pmass25", "PM2.5 (µg/m³)", 1},
	"pmass4":   {"pmass4", "PM4.0 (µg/m³)", 1},
	"pmass10":  {"pmass10", "PM10 (µg/m³)", 1},
	"HCHO":     {"HCHO", "Formaldehyde (ppb)", 1},
}

// Column order in the file, whatever order the metrics were picked in
var exportOrder = []string{"temp", "rH", "indoorTd", "CO2", "VOC", "NOx",
	"pmass1", "pmass25", "pmass4", "pmass10", "HCHO"}

func validInterval(n int) bool {
	if n == reportSeconds {
		return true
	}
	for _, step := range averagingSteps {
		if n == step {
			return true
		}
	}
	return false
}

// handleExport serves /api/export?location=1&location=2&metric=temp&metric=CO2
// &interval=900&startDate=2026-11-01T00:00:00&endDate=2026-11-23T23:59:59
// interval: 120 = every reading, or one of averagingSteps (seconds).
// Without startDate the export starts at the first reading.
func handleExport(w http.ResponseWriter, r *http.Request) {
	q := r.URL.Query()

	locations := []int{}
	for _, s := range q["location"] {
		n, ok := parseLocation(s)
		if !ok {
			http.Error(w, "Invalid location", http.StatusBadRequest)
			return
		}
		locations = append(locations, n)
	}
	if len(locations) == 0 {
		http.Error(w, "Choose at least one location", http.StatusBadRequest)
		return
	}

	picked := map[string]bool{}
	for _, m := range q["metric"] {
		if _, ok := exportMetrics[m]; !ok {
			http.Error(w, "Unknown metric: "+m, http.StatusBadRequest)
			return
		}
		picked[m] = true
	}
	metrics := []exportMetric{}
	for _, m := range exportOrder {
		if picked[m] {
			metrics = append(metrics, exportMetrics[m])
		}
	}
	if len(metrics) == 0 {
		http.Error(w, "Choose at least one metric", http.StatusBadRequest)
		return
	}

	interval := reportSeconds
	if s := q.Get("interval"); s != "" {
		n, err := strconv.Atoi(s)
		if err != nil || !validInterval(n) {
			http.Error(w, "Invalid interval", http.StatusBadRequest)
			return
		}
		interval = n
	}

	startDate, endDate := q.Get("startDate"), q.Get("endDate")
	for _, s := range []string{startDate, endDate} {
		if s != "" {
			if _, ok := parseRangeTime(s); !ok {
				http.Error(w, "Invalid date: "+s, http.StatusBadRequest)
				return
			}
		}
	}

	// Build the query. Columns, interval and decimals come from the tables
	// above, never from the request, so they are safe to put in the query.
	marks := strings.TrimSuffix(strings.Repeat("?,", len(locations)), ",")
	where := "WHERE location IN (" + marks + ")"
	args := []interface{}{}
	for _, l := range locations {
		args = append(args, l)
	}
	if startDate != "" {
		where += " AND measured_at >= ?"
		args = append(args, startDate)
	}
	if endDate != "" {
		where += " AND measured_at <= ?"
		args = append(args, endDate)
	}

	cols := []string{}
	var query string
	if interval == reportSeconds {
		for _, m := range metrics {
			cols = append(cols, fmt.Sprintf("CAST(%s AS DECIMAL(12,%d))", m.column, m.decimals))
		}
		query = fmt.Sprintf(`SELECT location, IFNULL(station_name, '') AS name, measured_at AS t, %s
			FROM sen55_display %s ORDER BY location, measured_at`, strings.Join(cols, ", "), where)
	} else {
		// Each interval is labeled with its start, on local clock time
		bucket := fmt.Sprintf("FLOOR(TO_SECONDS(measured_at) / %d) * %d", interval, interval)
		for _, m := range metrics {
			cols = append(cols, fmt.Sprintf("CAST(AVG(%s) AS DECIMAL(12,%d))", m.column, m.decimals))
		}
		query = fmt.Sprintf(`SELECT location, IFNULL(MAX(station_name), '') AS name,
			FROM_DAYS(%s DIV 86400) + INTERVAL (%s MOD 86400) SECOND AS t,
			COUNT(*) AS readings, %s
			FROM sen55_display %s
			GROUP BY location, %s ORDER BY location, t`,
			bucket, bucket, strings.Join(cols, ", "), where, bucket)
	}

	rows, err := db.Query(query, args...)
	if err != nil {
		log.Printf("Export query failed: %v", err)
		http.Error(w, "Export failed", http.StatusInternalServerError)
		return
	}
	defer rows.Close()

	name := "iaq_export_all.csv"
	if startDate != "" || endDate != "" {
		from, to := "start", "now"
		if startDate != "" {
			t, _ := parseRangeTime(startDate)
			from = t.Format("2006-01-02")
		}
		if endDate != "" {
			t, _ := parseRangeTime(endDate)
			to = t.Format("2006-01-02")
		}
		name = fmt.Sprintf("iaq_export_%s_to_%s.csv", from, to)
	}
	w.Header().Set("Content-Type", "text/csv; charset=utf-8")
	w.Header().Set("Content-Disposition", `attachment; filename="`+name+`"`)

	// A byte-order mark so Excel reads the file as UTF-8 (° and µ in headings)
	w.Write([]byte("\xEF\xBB\xBF"))
	out := csv.NewWriter(w)

	heading := []string{"Station", "Station name", "Time"}
	if interval != reportSeconds {
		heading[2] = "Interval start"
		heading = append(heading, "Readings averaged")
	}
	for _, m := range metrics {
		heading = append(heading, m.header)
	}
	out.Write(heading)

	extra := 0
	if interval != reportSeconds {
		extra = 1
	}
	var station, stationName string
	var t time.Time
	values := make([]sql.NullString, extra+len(metrics))
	dest := []interface{}{&station, &stationName, &t}
	for i := range values {
		dest = append(dest, &values[i])
	}
	record := make([]string, 3+len(values))
	n := 0
	for rows.Next() {
		if err := rows.Scan(dest...); err != nil {
			log.Printf("Export read failed after %d rows: %v", n, err)
			break
		}
		record[0], record[1], record[2] = station, stationName, t.Format("2006-01-02 15:04:05")
		for i, v := range values {
			record[3+i] = v.String // empty when there was no reading
		}
		out.Write(record)
		n++
		if n%2000 == 0 {
			out.Flush()
		}
	}
	if err := rows.Err(); err != nil {
		log.Printf("Export stopped after %d rows: %v", n, err)
	}
	out.Flush()
	log.Printf("Exported %d rows (%d stations, %d metrics, %d s interval)", n, len(locations), len(metrics), interval)
}
