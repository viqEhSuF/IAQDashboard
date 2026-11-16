# IAQDashboard — Raspberry Pi Deployment Checklist

Target: Raspberry Pi 4 or 5 running 64-bit Raspberry Pi OS.

> **This is the `v2` branch**, for systems on the new database schema
> (`database/iaq_schema.sql`), where stations post raw readings to
> `ingest/iaq_ingest.php` and calibration is applied in the database.
> Systems still on the old `IAQ_SEN55` table stay on `main`.

---

## Prerequisites

- [ ] The Pi has internet access (for downloading dependencies)
- [ ] You know the Pi's local IP address (`hostname -I`)
- [ ] Stations run the matching firmware (`IAQ_SEN55_station.ino`, version `r4-sen55-2.x`)

---

## 1 — Install dependencies

### Apache, PHP and MariaDB
```bash
sudo apt update
sudo apt install -y apache2 libapache2-mod-php php-mysql mariadb-server
sudo systemctl enable apache2
sudo systemctl start apache2
```

### Go (ARM64 — Pi 4/5)
```bash
wget https://go.dev/dl/go1.21.4.linux-arm64.tar.gz
sudo tar -C /usr/local -xzf go1.21.4.linux-arm64.tar.gz
echo 'export PATH=$PATH:/usr/local/go/bin' >> ~/.bashrc
source ~/.bashrc
go version
# Expected: go version go1.21.4 linux/arm64
```

### Bun (JavaScript runtime)
```bash
curl -fsSL https://bun.sh/install | bash
source ~/.bashrc
bun --version
```

---

## 2 — Clone the repository (v2 branch)

```bash
git clone -b v2 https://github.com/viqEhSuF/IAQDashboard.git ~/IAQDashboard
```

The auto-updater follows the branch the copy was cloned on, so this system
will only receive `v2` updates.

---

## 2a — Create the database

Copy the schema, set real passwords in the copy (section 5 of the file), and
run it. Keep the real passwords out of the repository.

```bash
cp ~/IAQDashboard/database/iaq_schema.sql ~/iaq_schema.sql
nano ~/iaq_schema.sql      # replace CHANGE_ME_INGEST and CHANGE_ME_DASHBOARD
sudo mariadb < ~/iaq_schema.sql
rm ~/iaq_schema.sql
```

This creates the `buildingData` database and two local-only accounts:
`iaq_ingest` for the ingest script and `iaq_dashboard` for the API below.

---

## 2b — Install the ingest script

```bash
sudo mkdir -p /etc/iaq
sudo cp ~/IAQDashboard/ingest/iaq_config.php /etc/iaq/config.php
sudo nano /etc/iaq/config.php      # set IAQ_DB_PASS to the iaq_ingest password
sudo chown root:www-data /etc/iaq/config.php
sudo chmod 640 /etc/iaq/config.php
sudo cp ~/IAQDashboard/ingest/iaq_ingest.php /var/www/html/iaq_ingest.php
```

`iaq_ingest.php` accepts readings only from the station network
(`IAQ_STATION_PREFIX` in the config, `192.168.10.` by default). Stations
register themselves on their first post and appear in the dashboard, where
they can be renamed.

---

## 3 — Build and install the Go API

```bash
cd ~/IAQDashboard/sensor-api
go build -o sensor-api .
sudo cp sensor-api /usr/local/bin/sensor-api
```

Verify the binary exists:
```bash
ls -lh /usr/local/bin/sensor-api
```

---

## 4 — Create the systemd service

```bash
sudo nano /etc/systemd/system/sensor-api.service
```

Paste the following, replacing `MYSQL_PASS` with the `iaq_dashboard` password:

```ini
[Unit]
Description=IAQ Sensor API
After=network.target mysql.service mariadb.service

[Service]
ExecStart=/usr/local/bin/sensor-api
Restart=always
RestartSec=5
Environment=PORT=8080
Environment=MYSQL_HOST=localhost
Environment=MYSQL_PORT=3306
Environment=MYSQL_USER=iaq_dashboard
Environment=MYSQL_PASS=your_dashboard_password
Environment=MYSQL_DB=buildingData

[Install]
WantedBy=multi-user.target
```

Enable and start:
```bash
sudo systemctl daemon-reload
sudo systemctl enable sensor-api
sudo systemctl start sensor-api
```

Confirm it is running:
```bash
sudo systemctl status sensor-api
# Should show: Active: active (running)
```

Check the API responds:
```bash
curl http://localhost:8080/api/locations
# Returns [] until a station has posted, then one entry per station
# An error message instead means the API can't reach the database
```

---

## 5 — Configure Apache reverse proxy

Enable the required Apache modules:
```bash
sudo a2enmod proxy proxy_http
```

Open the default site config:
```bash
sudo nano /etc/apache2/sites-enabled/000-default.conf
```

Add these two lines **inside** the `<VirtualHost *:80>` block, before the closing `</VirtualHost>`:
```apache
ProxyPass /api/ http://localhost:8080/api/
ProxyPassReverse /api/ http://localhost:8080/api/
```

Restart Apache:
```bash
sudo systemctl restart apache2
```

Verify the proxy works:
```bash
curl http://localhost/api/locations
# Should return the same JSON as the direct API call above
```

---

## 6 — Build and deploy the frontend

The build needs about 1.5 GB of memory. On a Pi with 1 GB it runs out and
appears to hang partway through `transforming (…)`; build it on another
computer instead (below). With 4 GB or more, build on the Pi:

```bash
cd ~/IAQDashboard/sensor-dashboard
bun install
bun run deploy
# This runs: vite build && sudo cp -r build/* /var/www/html/
```

**Building on another computer** (any Linux, macOS or Windows machine with
[Bun](https://bun.sh) installed). The built dashboard is plain files, so it
runs on the Pi unchanged:

```bash
git clone -b v2 https://github.com/viqEhSuF/IAQDashboard.git
cd IAQDashboard/sensor-dashboard
bun install
bun run build
scp -r build pi-user@<pi-ip>:~/dashboard-build
```

Then on the Pi:

```bash
sudo cp -r ~/dashboard-build/* /var/www/html/
rm -rf ~/dashboard-build
```

Copying the files doesn't remove `iaq_ingest.php`, which also lives in
`/var/www/html/`.

---

## 7 — Verify the dashboard

- [ ] Open `http://<pi-ip>/` in a browser on the local network
- [ ] The dark header loads with the title "IAQ Dashboard"
- [ ] Sensor location buttons appear (one per station that has posted)
- [ ] The Station Health panel shows each station as OK, with a recent report time
- [ ] Selecting a location updates all charts
- [ ] Date range presets (Last Hour, Last 6 Hours, Last 24 Hours) work
- [ ] Charts load data and the crosshair tooltip appears on hover
- [ ] No errors in the browser console (F12 → Console)

---

## Automatic daily updates

The repository includes `update.sh`, which checks for upstream changes once per day and rebuilds only what changed. Set it up with a systemd timer:

**1 — Make the script executable and allow root to run git in the repo:**
```bash
chmod +x ~/IAQDashboard/update.sh
sudo git config --system --add safe.directory ~/IAQDashboard
```
The second command writes to `/etc/gitconfig` so that the service (which runs as root) can run git commands in a directory owned by your regular user. This is a one-time step.

**2 — Create the systemd service** (`/etc/systemd/system/iaq-update.service`):

First, get the correct path for your user:
```bash
echo "ExecStart=$(readlink -f ~/IAQDashboard/update.sh)"
```
Copy the output — you will paste it into the service file below.

```bash
sudo nano /etc/systemd/system/iaq-update.service
```
```ini
[Unit]
Description=IAQ Dashboard Auto-Update
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/home/YOUR_USERNAME/IAQDashboard/update.sh
StandardOutput=append:/var/log/iaq-update.log
StandardError=append:/var/log/iaq-update.log
```
Replace `YOUR_USERNAME` with your actual username (e.g. `data`, not `pi`).

**3 — Create the systemd timer** (`/etc/systemd/system/iaq-update.timer`):
```bash
sudo nano /etc/systemd/system/iaq-update.timer
```
```ini
[Unit]
Description=Daily IAQ Dashboard Auto-Update

[Timer]
OnCalendar=daily
Persistent=true
RandomizedDelaySec=1800

[Install]
WantedBy=timers.target
```

> `Persistent=true` means the update runs immediately on next boot if the Pi was off when the timer was due. `RandomizedDelaySec=1800` staggers updates by up to 30 minutes so multiple Pis don't all hit GitHub at midnight simultaneously.

**4 — Enable and start the timer:**
```bash
sudo systemctl daemon-reload
sudo systemctl enable iaq-update.timer
sudo systemctl start iaq-update.timer
```

**5 — Verify it is scheduled:**
```bash
systemctl list-timers iaq-update.timer
```

**To trigger an update immediately** (useful for testing):
```bash
sudo systemctl start iaq-update.service
```

**To view the update log:**
```bash
cat /var/log/iaq-update.log
```

---

## Updating after a code change

```bash
cd ~/IAQDashboard
git pull

# Rebuild API if sensor-api/main.go changed
cd sensor-api
go build -o sensor-api .
sudo systemctl stop sensor-api
sudo cp sensor-api /usr/local/bin/sensor-api
sudo systemctl start sensor-api

# Rebuild frontend if sensor-dashboard/ changed
cd ../sensor-dashboard
bun install   # only needed if package.json changed
bun run deploy
```

---

## Troubleshooting

| Symptom | Check |
|---|---|
| Page loads but shows "Connection error" | `sudo systemctl status sensor-api` — is it running? Check DB credentials in the service file |
| API returns 500 | `sudo journalctl -u sensor-api -n 50` — look for SQL errors (wrong column names, missing table) |
| No locations appear | No station has posted yet. Check the station's serial monitor for `Server: HTTP/1.1 200 OK`, and `sudo grep "IAQ ingest" /var/log/apache2/error.log` |
| Station shows Offline | It has not reported for over 10 minutes: check its power and WiFi |
| Temperatures read a few degrees high | The station has no `temp_c` calibration row yet; see section 6 of `database/iaq_schema.sql` |
| `go: command not found` | Re-run `source ~/.bashrc` or log out and back in |
| `bun: command not found` | Re-run `source ~/.bashrc` or log out and back in |
| `cp: Text file busy` when copying sensor-api | Stop the service first: `sudo systemctl stop sensor-api`, then copy, then start |
| Charts show no data | Confirm the date range matches when data was recorded; check the selected location has data |
| Crosshair tracks in wrong direction | Data may be arriving in descending order — confirm `createTimeSeriesData` sorts ascending by `x` |
