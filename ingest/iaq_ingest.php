<?php
// Receives averaged readings from the IAQ stations (IAQ_SEN55_station.ino)
// and stores them raw in sen55_readings. Calibration is applied by the
// database views, not here.
//
// Install in the web root, e.g. /var/www/html/iaq_ingest.php
// Settings and credentials: /etc/iaq/config.php (outside the web root)
//
// Responds 200 "OK" when the reading is stored; otherwise a 4xx/5xx status,
// which the station reports on its serial monitor.

require '/etc/iaq/config.php';

header('Content-Type: text/plain');

function fail(int $code, string $msg): void
{
    http_response_code($code);
    echo $msg;
    exit;
}

// Accept readings only from the station network. Requests arriving through
// the Cloudflare tunnel come from localhost, so they are refused too.
$ip = $_SERVER['REMOTE_ADDR'] ?? '';
if (IAQ_STATION_PREFIX !== '' &&
    (strpos($ip, IAQ_STATION_PREFIX) !== 0 || $ip === IAQ_GATEWAY_IP)) {
    error_log("IAQ ingest: refused request from $ip");
    fail(403, 'forbidden');
}

if ($_SERVER['REQUEST_METHOD'] !== 'POST') {
    fail(405, 'POST only');
}

// Station number, 1-65535 (the LOCATION constant in the firmware)
$station = filter_input(INPUT_POST, 'station', FILTER_VALIDATE_INT,
                        ['options' => ['min_range' => 1, 'max_range' => 65535]]);
if ($station === false || $station === null) {
    fail(400, 'invalid station');
}

// Firmware version: letters, digits, dot, dash and underscore, up to 32 characters
$fw = $_POST['fw'] ?? '';
$fw = preg_match('/^[A-Za-z0-9._-]{1,32}$/', $fw) ? $fw : null;

// Missing, empty, non-numeric or out-of-range values become NULL
function num(string $key, float $min, float $max): ?float
{
    $v = filter_input(INPUT_POST, $key, FILTER_VALIDATE_FLOAT);
    if ($v === false || $v === null) {
        return null;
    }
    return ($v >= $min && $v <= $max) ? $v : null;
}

function int_or_null(string $key, int $min, int $max): ?int
{
    $v = filter_input(INPUT_POST, $key, FILTER_VALIDATE_INT,
                      ['options' => ['min_range' => $min, 'max_range' => $max]]);
    return ($v === false || $v === null) ? null : $v;
}

// Ranges are the sensors' output ranges
$temp_c = num('temp_c', -40, 85);     // deg C
$rh     = num('rh',       0, 100);    // %
$pm1    = num('pm1',      0, 1000);   // ug/m3
$pm25   = num('pm25',     0, 1000);
$pm4    = num('pm4',      0, 1000);
$pm10   = num('pm10',     0, 1000);
$voc    = num('voc',      1, 500);    // index
$nox    = num('nox',      1, 500);    // index
$hcho   = num('hcho',   -50, 1000);   // ppb
$co2    = int_or_null('co2',    0, 40000);        // ppm
$status = int_or_null('status', 0, 4294967295);   // SEN55 device status register
$rssi   = int_or_null('rssi', -127, 0);           // dBm
$uptime = int_or_null('uptime', 0, 4294967295);   // seconds since boot

mysqli_report(MYSQLI_REPORT_ERROR | MYSQLI_REPORT_STRICT);

try {
    $con = new mysqli(IAQ_DB_HOST, IAQ_DB_USER, IAQ_DB_PASS, IAQ_DB_NAME);

    // Register a new station number on its first post, and keep the firmware
    // version current. A post without a valid version leaves it unchanged.
    $reg = $con->prepare(
        'INSERT INTO stations (station_id, firmware) VALUES (?, ?)
         ON DUPLICATE KEY UPDATE firmware = COALESCE(VALUES(firmware), firmware)'
    );
    $reg->bind_param('is', $station, $fw);
    $reg->execute();
    $reg->close();

    // measured_at is set by the database
    $ins = $con->prepare(
        'INSERT INTO sen55_readings
            (station_id, temp_c, rh, pm1, pm25, pm4, pm10, voc, nox, hcho, co2,
             sen55_status, rssi_dbm, uptime_s)
         VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)'
    );
    $ins->bind_param(
        'idddddddddiiii',
        $station, $temp_c, $rh, $pm1, $pm25, $pm4, $pm10, $voc, $nox, $hcho,
        $co2, $status, $rssi, $uptime
    );
    $ins->execute();
    $ins->close();
    $con->close();
} catch (mysqli_sql_exception $e) {
    error_log('IAQ ingest: ' . $e->getMessage());
    fail(500, 'database error');
}

echo 'OK';
