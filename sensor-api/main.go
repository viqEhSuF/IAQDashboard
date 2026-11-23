package main

import (
	"database/sql"
	"encoding/json"
	"fmt"
	"log"
	"math"
	"net/http"
	"os"
	"strconv"
	"strings"
	"time"

	_ "github.com/go-sql-driver/mysql"
	"github.com/gorilla/mux"
	"github.com/jmoiron/sqlx"
	"github.com/rs/cors"
)

// SensorData is one reading from the sen55_display view: calibration applied,
// temperature and dew point in deg F. Measurements are pointers because a
// value can be missing (NULL) and is then sent to the dashboard as null.
type SensorData struct {
	Location  string    `json:"location" db:"location"`
	RecTime   time.Time `json:"recTime" db:"recTime"`
	Timestamp string    `json:"timestamp" db:"-"`
	Temp      *float64  `json:"temp" db:"temp"`
	RH        *float64  `json:"rH" db:"rH"`
	VOC       *float64  `json:"VOC" db:"VOC"`
	NOx       *float64  `json:"NOx" db:"NOx"`
	Pmass1    *float64  `json:"pmass1" db:"pmass1"`
	Pmass25   *float64  `json:"pmass25" db:"pmass25"`
	Pmass4    *float64  `json:"pmass4" db:"pmass4"`
	Pmass10   *float64  `json:"pmass10" db:"pmass10"`
	HCHO      *float64  `json:"HCHO" db:"HCHO"`
	CO2       *float64  `json:"CO2" db:"CO2"`
	IndoorTd  *float64  `json:"indoorTd" db:"DP"`
	Tags      []string  `json:"tags,omitempty"` // Optional tags field
}

// LocationData represents one sensor station
type LocationData struct {
	Location string `json:"location" db:"location"`
}

// StationHealth is one row of the station_health view
type StationHealth struct {
	Location         string     `json:"location" db:"location"`
	Name             *string    `json:"name" db:"name"`
	Firmware         *string    `json:"firmware" db:"firmware"`
	LastReading      *time.Time `json:"lastReading" db:"last_reading"`
	MinutesSinceLast *int64     `json:"minutesSinceLast" db:"minutes_since_last"`
	RSSI             *int64     `json:"rssi" db:"rssi_dbm"`
	UptimeS          *int64     `json:"uptimeS" db:"uptime_s"`
	FanError         bool       `json:"fanError" db:"fan_error"`
	LaserError       bool       `json:"laserError" db:"laser_error"`
	RHTError         bool       `json:"rhtError" db:"rht_error"`
	GasSensorError   bool       `json:"gasSensorError" db:"gas_sensor_error"`
	FanSpeedWarning  bool       `json:"fanSpeedWarning" db:"fan_speed_warning"`

	// Whether the last report had no readings from each sensor (null = never reported)
	Sen55NoData *bool `json:"sen55NoData" db:"sen55_no_data"`
	CO2NoData   *bool `json:"co2NoData" db:"co2_no_data"`
	HCHONoData  *bool `json:"hchoNoData" db:"hcho_no_data"`
}

// Database configuration - same as in your TypeScript app
var dbConfig struct {
	Host     string
	User     string
	Password string
	Database string
	Port     int
}

var db *sqlx.DB
var err error

// Initialize database connection
func initDB() error {
	dbConfig.User = os.Getenv("MYSQL_USER")
	dbConfig.Password = os.Getenv("MYSQL_PASS")
	dbConfig.Host = os.Getenv("MYSQL_HOST")
	port := os.Getenv("MYSQL_PORT")
	dbConfig.Database = os.Getenv("MYSQL_DB")

	dbConfig.Port, err = strconv.Atoi(port)
	if err != nil {
		log.Printf("Error converting port to int: %v", err)
		log.Printf("Using default port 3306")
		dbConfig.Port = 3306
	}
	dsn := fmt.Sprintf("%s:%s@tcp(%s:%d)/%s?parseTime=true&loc=Local",
		dbConfig.User, dbConfig.Password, dbConfig.Host, dbConfig.Port, dbConfig.Database)

	var err error
	db, err = sqlx.Connect("mysql", dsn)
	if err != nil {
		return err
	}

	// Set connection pool settings
	db.SetMaxOpenConns(25)
	db.SetMaxIdleConns(5)
	db.SetConnMaxLifetime(5 * time.Minute)

	return nil
}

// Sanitize sensor data: NaN or Infinity can't be encoded as JSON, so treat
// them as missing values
func sanitizeSensorData(data *SensorData) {
	for _, v := range []**float64{
		&data.Temp, &data.RH, &data.VOC, &data.NOx, &data.Pmass1, &data.Pmass25,
		&data.Pmass4, &data.Pmass10, &data.HCHO, &data.CO2, &data.IndoorTd,
	} {
		if *v != nil && (math.IsNaN(**v) || math.IsInf(**v, 0)) {
			*v = nil
		}
	}
}

// parseLocation validates a station number from a URL or query parameter
func parseLocation(s string) (int, bool) {
	n, err := strconv.Atoi(s)
	return n, err == nil && n >= 1 && n <= 65535
}

// GetLocationNames returns all station names as a map[location]name
func GetLocationNames() (map[string]string, error) {
	rows, err := db.Query("SELECT station_id, name FROM stations WHERE name IS NOT NULL")
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	m := make(map[string]string)
	for rows.Next() {
		var id int
		var name string
		if err := rows.Scan(&id, &name); err != nil {
			return nil, err
		}
		m[strconv.Itoa(id)] = name
	}
	return m, rows.Err()
}

// SetLocationName sets the display name of a station; NULL clears it
func SetLocationName(location int, name sql.NullString) error {
	_, err := db.Exec("UPDATE stations SET name = ? WHERE station_id = ?", name, location)
	return err
}

// handleGetLocationNames returns all station names as a JSON object.
func handleGetLocationNames(w http.ResponseWriter, r *http.Request) {
	names, err := GetLocationNames()
	if err != nil {
		log.Printf("Error fetching location names: %v", err)
		http.Error(w, "Failed to fetch location names", http.StatusInternalServerError)
		return
	}
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(names)
}

// handlePutLocationName sets the name of a single station.
func handlePutLocationName(w http.ResponseWriter, r *http.Request) {
	location, ok := parseLocation(mux.Vars(r)["location"])
	if !ok {
		http.Error(w, "Invalid location", http.StatusBadRequest)
		return
	}
	var body struct {
		Name string `json:"name"`
	}
	if err := json.NewDecoder(r.Body).Decode(&body); err != nil || strings.TrimSpace(body.Name) == "" {
		http.Error(w, "Invalid request body", http.StatusBadRequest)
		return
	}
	name := strings.TrimSpace(body.Name)
	if len([]rune(name)) > 64 {
		http.Error(w, "Name too long (64 characters maximum)", http.StatusBadRequest)
		return
	}
	if err := SetLocationName(location, sql.NullString{String: name, Valid: true}); err != nil {
		log.Printf("Error setting location name: %v", err)
		http.Error(w, "Failed to set location name", http.StatusInternalServerError)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

// handleDeleteLocationName clears the name of a station.
func handleDeleteLocationName(w http.ResponseWriter, r *http.Request) {
	location, ok := parseLocation(mux.Vars(r)["location"])
	if !ok {
		http.Error(w, "Invalid location", http.StatusBadRequest)
		return
	}
	if err := SetLocationName(location, sql.NullString{}); err != nil {
		log.Printf("Error deleting location name: %v", err)
		http.Error(w, "Failed to delete location name", http.StatusInternalServerError)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

// GetLocations returns the active stations
func GetLocations() ([]LocationData, error) {
	// Start from an empty list so no stations encodes as [] rather than null
	locations := []LocationData{}
	err := db.Select(&locations,
		"SELECT CAST(station_id AS CHAR) AS location FROM stations WHERE active = 1 ORDER BY station_id")
	if err != nil {
		return nil, err
	}
	return locations, nil
}

// GetSensorData retrieves sensor data from the database with optional filtering
// Charts get at most about this many points per station. A longer range is
// averaged into fixed intervals so the whole range fits, instead of losing its
// oldest readings to the row limit; zooming in fetches the shorter window at
// full detail.
const maxPointsPerStation = 3000

// Stations report every 2 minutes
const reportSeconds = 120

// Interval lengths a long range is averaged into, in seconds
var averagingSteps = []int{300, 600, 900, 1800, 3600, 7200, 10800, 21600, 43200, 86400}

// resolutionFor returns the interval to average a range into: reportSeconds
// (no averaging) when the whole range fits at full detail.
func resolutionFor(start, end time.Time) int {
	span := end.Sub(start).Seconds()
	if span <= float64(maxPointsPerStation*reportSeconds) {
		return reportSeconds
	}
	need := span / maxPointsPerStation
	for _, step := range averagingSteps {
		if float64(step) >= need {
			return step
		}
	}
	return averagingSteps[len(averagingSteps)-1]
}

// parseRangeTime reads a startDate/endDate parameter as local time
func parseRangeTime(s string) (time.Time, bool) {
	for _, layout := range []string{"2006-01-02T15:04:05", "2006-01-02 15:04:05", "2006-01-02T15:04", "2006-01-02"} {
		if t, err := time.ParseInLocation(layout, s, time.Local); err == nil {
			return t, true
		}
	}
	return time.Time{}, false
}

// earliestReading is the time of the first reading for a station (0 = all)
func earliestReading(location int) (time.Time, bool) {
	var t sql.NullTime
	var err error
	if location > 0 {
		err = db.Get(&t, "SELECT MIN(measured_at) FROM sen55_readings WHERE station_id = ?", location)
	} else {
		err = db.Get(&t, "SELECT MIN(measured_at) FROM sen55_readings")
	}
	if err != nil || !t.Valid {
		return time.Time{}, false
	}
	return t.Time, true
}

// rangeResolution works out the averaging interval for a sensor-data request
func rangeResolution(startDate, endDate string, location int) int {
	end := time.Now()
	if endDate != "" {
		t, ok := parseRangeTime(endDate)
		if !ok {
			return reportSeconds
		}
		end = t
	}
	var start time.Time
	if startDate != "" {
		t, ok := parseRangeTime(startDate)
		if !ok {
			return reportSeconds
		}
		start = t
	} else {
		t, ok := earliestReading(location)
		if !ok {
			return reportSeconds
		}
		start = t
	}
	return resolutionFor(start, end)
}

// GetSensorData returns readings for a time range, newest first. With
// resolution above reportSeconds, each station's readings are averaged over
// intervals of that many seconds (on local clock time); each point is placed
// at the average time of the readings in it.
func GetSensorData(limit int, startDate, endDate string, location, resolution int) ([]SensorData, error) {
	query := `SELECT CAST(location AS CHAR) AS location, measured_at AS recTime,
	                 temp, rH, VOC, NOx, pmass1, pmass25, pmass4, pmass10, HCHO, CO2, DP
	          FROM sen55_display`
	if resolution > reportSeconds {
		query = `SELECT CAST(location AS CHAR) AS location,
		                FROM_UNIXTIME(ROUND(AVG(UNIX_TIMESTAMP(measured_at)))) AS recTime,
		                ROUND(AVG(temp), 2) AS temp, ROUND(AVG(rH), 2) AS rH,
		                ROUND(AVG(VOC), 2) AS VOC, ROUND(AVG(NOx), 2) AS NOx,
		                ROUND(AVG(pmass1), 2) AS pmass1, ROUND(AVG(pmass25), 2) AS pmass25,
		                ROUND(AVG(pmass4), 2) AS pmass4, ROUND(AVG(pmass10), 2) AS pmass10,
		                ROUND(AVG(HCHO), 2) AS HCHO, ROUND(AVG(CO2), 1) AS CO2, ROUND(AVG(DP), 2) AS DP
		         FROM sen55_display`
	}
	conditions := []string{}
	args := []interface{}{}

	if location > 0 {
		conditions = append(conditions, "location = ?")
		args = append(args, location)
	}

	// Add date filtering if provided
	if startDate != "" {
		conditions = append(conditions, "measured_at >= ?")
		args = append(args, startDate)
	}

	if endDate != "" {
		conditions = append(conditions, "measured_at <= ?")
		args = append(args, endDate)
	}

	// Build the WHERE clause if conditions exist
	if len(conditions) > 0 {
		query += " WHERE " + strings.Join(conditions, " AND ")
	}

	// Add grouping, sorting and limit. resolution is one of averagingSteps,
	// never user text, so it is safe to put in the query.
	if resolution > reportSeconds {
		query += fmt.Sprintf(" GROUP BY location, FLOOR(TO_SECONDS(measured_at) / %d) ORDER BY recTime DESC LIMIT ?", resolution)
	} else {
		query += " ORDER BY measured_at DESC LIMIT ?"
	}
	args = append(args, limit)

	// Execute the query. Start from an empty list so no rows encodes as []
	// rather than null.
	data := []SensorData{}
	err := db.Select(&data, query, args...)
	if err != nil {
		return nil, err
	}

	for i := range data {
		sanitizeSensorData(&data[i])
		// Add timestamp field from recTime for consistency with TypeScript API
		data[i].Timestamp = data[i].RecTime.Format(time.RFC3339)
	}

	return data, nil
}

// GetStationHealth returns one row per active station from station_health
func GetStationHealth() ([]StationHealth, error) {
	var rows []StationHealth
	err := db.Select(&rows, `
		SELECT CAST(station_id AS CHAR) AS location, name, firmware, last_reading,
		       minutes_since_last, rssi_dbm, uptime_s,
		       sen55_no_data, co2_no_data, hcho_no_data,
		       COALESCE(fan_error_24h, 0)         AS fan_error,
		       COALESCE(laser_error_24h, 0)       AS laser_error,
		       COALESCE(rht_error_24h, 0)         AS rht_error,
		       COALESCE(gas_sensor_error_24h, 0)  AS gas_sensor_error,
		       COALESCE(fan_speed_warning_24h, 0) AS fan_speed_warning
		FROM station_health
		ORDER BY station_id`)
	return rows, err
}

// API handler for listing the active stations
func handleGetLocations(w http.ResponseWriter, r *http.Request) {
	locations, err := GetLocations()
	if err != nil {
		log.Printf("Error fetching locations: %v", err)
		http.Error(w, "Failed to fetch locations", http.StatusInternalServerError)
		return
	}
	w.Header().Set("Content-Type", "application/json")
	if err := json.NewEncoder(w).Encode(locations); err != nil {
		log.Printf("Error encoding locations response: %v", err)
		http.Error(w, "Error encoding response", http.StatusInternalServerError)
	}
}

// API handler for getting sensor data
func handleGetSensorData(w http.ResponseWriter, r *http.Request) {
	// Get query parameters
	startDate := r.URL.Query().Get("startDate")
	endDate := r.URL.Query().Get("endDate")
	locationStr := r.URL.Query().Get("location")
	limitStr := r.URL.Query().Get("limit")

	location := 0
	if locationStr != "" {
		var ok bool
		if location, ok = parseLocation(locationStr); !ok {
			http.Error(w, "Invalid location", http.StatusBadRequest)
			return
		}
	}

	// Default limit to 15000, as in your TypeScript API
	limit := 15000
	if limitStr != "" {
		parsedLimit, err := strconv.Atoi(limitStr)
		if err == nil && parsedLimit > 0 {
			limit = parsedLimit
		}
	}

	log.Printf("Fetching data with range: %s to %s, location: %q, limit: %d", startDate, endDate, locationStr, limit)

	// Long ranges come back averaged so the whole range fits under the limit
	resolution := rangeResolution(startDate, endDate, location)

	// Get data from database
	data, err := GetSensorData(limit, startDate, endDate, location, resolution)
	if err != nil {
		log.Printf("Error fetching sensor data: %v", err)
		http.Error(w, "Failed to fetch sensor data", http.StatusInternalServerError)
		return
	}

	log.Printf("Returned %d records at %d s resolution", len(data), resolution)

	// Add tag support - for demo, just add a tag based on temperature
	for i := range data {
		// Example of adding tags based on sensor values
		if t := data[i].Temp; t != nil {
			if *t > 25 {
				data[i].Tags = append(data[i].Tags, "high-temperature")
			} else if *t < 18 {
				data[i].Tags = append(data[i].Tags, "low-temperature")
			}
		}

		if c := data[i].CO2; c != nil && *c > 1000 {
			data[i].Tags = append(data[i].Tags, "high-co2")
		}
	}

	// Set content type header
	// Seconds each point covers: 120 is every reading, more is averaged
	w.Header().Set("X-Resolution-Seconds", strconv.Itoa(resolution))
	w.Header().Set("Content-Type", "application/json")

	// Return as JSON
	if err := json.NewEncoder(w).Encode(data); err != nil {
		log.Printf("Error encoding response: %v", err)
		http.Error(w, "Error encoding response", http.StatusInternalServerError)
	}
}

// API handler for getting latest sensor data
func handleGetLatestSensorData(w http.ResponseWriter, r *http.Request) {
	// Get query parameters
	limitStr := r.URL.Query().Get("limit")

	// Default limit to 1
	limit := 1
	if limitStr != "" {
		parsedLimit, err := strconv.Atoi(limitStr)
		if err == nil && parsedLimit > 0 {
			limit = parsedLimit
		}
	}

	// Get latest data from database
	data, err := GetSensorData(limit, "", "", 0, reportSeconds)
	if err != nil {
		log.Printf("Error fetching latest sensor data: %v", err)
		http.Error(w, "Failed to fetch latest sensor data", http.StatusInternalServerError)
		return
	}

	// Set content type header
	w.Header().Set("Content-Type", "application/json")

	// Return as JSON
	if err := json.NewEncoder(w).Encode(data); err != nil {
		log.Printf("Error encoding response: %v", err)
		http.Error(w, "Error encoding response", http.StatusInternalServerError)
	}
}

// API handler for station health: last report, signal and SEN55 faults
func handleGetStationHealth(w http.ResponseWriter, r *http.Request) {
	rows, err := GetStationHealth()
	if err != nil {
		log.Printf("Error fetching station health: %v", err)
		http.Error(w, "Failed to fetch station health", http.StatusInternalServerError)
		return
	}
	if rows == nil {
		rows = []StationHealth{}
	}
	w.Header().Set("Content-Type", "application/json")
	if err := json.NewEncoder(w).Encode(rows); err != nil {
		log.Printf("Error encoding station health: %v", err)
	}
}

func main() {
	// Initialize database connection
	if err := initDB(); err != nil {
		log.Fatalf("Failed to connect to database: %v", err)
	}
	defer db.Close()

	// Create router
	r := mux.NewRouter()

	// Define API routes. Readings are written only by the stations, through
	// iaq_ingest.php; this API reads them.
	r.HandleFunc("/api/locations", handleGetLocations).Methods("GET")
	r.HandleFunc("/api/location-names", handleGetLocationNames).Methods("GET")
	r.HandleFunc("/api/location-names/{location}", handlePutLocationName).Methods("PUT")
	r.HandleFunc("/api/location-names/{location}", handleDeleteLocationName).Methods("DELETE")
	r.HandleFunc("/api/sensor-data", handleGetSensorData).Methods("GET")
	r.HandleFunc("/api/sensor-data/latest", handleGetLatestSensorData).Methods("GET")
	r.HandleFunc("/api/station-health", handleGetStationHealth).Methods("GET")

	// Add CORS support
	c := cors.New(cors.Options{
		AllowedOrigins:   []string{"*"}, // Adjust this for production
		AllowedMethods:   []string{"GET", "PUT", "DELETE"},
		AllowedHeaders:   []string{"Content-Type", "Authorization"},
		ExposedHeaders:   []string{"X-Resolution-Seconds"},
		AllowCredentials: true,
	})

	// Define server
	port := os.Getenv("PORT")
	if port == "" {
		port = "8080"
	}

	server := &http.Server{
		Addr:    ":" + port,
		Handler: c.Handler(r),
	}

	// Start server
	log.Printf("Starting sensor API server on port %s...", port)
	if err := server.ListenAndServe(); err != nil {
		log.Fatalf("Server error: %v", err)
	}
}
