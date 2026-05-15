# IAQDashboard — Raspberry Pi Deployment Checklist

Target: Raspberry Pi 4 or 5 running Raspberry Pi OS (64-bit recommended).

---

## Prerequisites

- [ ] MariaDB is installed and running with the `IAQ_SEN55` table populated
- [ ] You have the database name, username, and password to hand
- [ ] The Pi has internet access (for downloading dependencies)
- [ ] You know the Pi's local IP address (`hostname -I`)

---

## 1 — Install dependencies

### Apache web server
```bash
sudo apt update
sudo apt install -y apache2
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

## 2 — Clone the repository

```bash
git clone https://github.com/viqEhSuF/IAQDashboard.git ~/IAQDashboard
```

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

Paste the following, replacing the `MYSQL_*` values with your actual credentials:

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
Environment=MYSQL_USER=your_db_user
Environment=MYSQL_PASS=your_db_password
Environment=MYSQL_DB=your_db_name

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
# Should return a JSON array of location objects
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

```bash
cd ~/IAQDashboard/sensor-dashboard
bun install
bun run deploy
# This runs: vite build && sudo cp -r build/* /var/www/html/
```

---

## 7 — Verify the dashboard

- [ ] Open `http://<pi-ip>/` in a browser on the local network
- [ ] The dark header loads with the title "IAQ Dashboard"
- [ ] Sensor location buttons appear (one per distinct location in the DB)
- [ ] Selecting a location updates all charts
- [ ] Date range presets (Last Hour, Last 6 Hours, Last 24 Hours) work
- [ ] Charts load data and the crosshair tooltip appears on hover
- [ ] No errors in the browser console (F12 → Console)

---

## Automatic daily updates

The repository includes `update.sh`, which checks for upstream changes once per day and rebuilds only what changed. Set it up with a systemd timer:

**1 — Make the script executable:**
```bash
chmod +x ~/IAQDashboard/update.sh
```

**2 — Create the systemd service** (`/etc/systemd/system/iaq-update.service`):
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
ExecStart=/home/pi/IAQDashboard/update.sh
StandardOutput=append:/var/log/iaq-update.log
StandardError=append:/var/log/iaq-update.log
```

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
| `go: command not found` | Re-run `source ~/.bashrc` or log out and back in |
| `bun: command not found` | Re-run `source ~/.bashrc` or log out and back in |
| `cp: Text file busy` when copying sensor-api | Stop the service first: `sudo systemctl stop sensor-api`, then copy, then start |
| Charts show no data | Confirm the date range matches when data was recorded; check the selected location has data |
| Crosshair tracks in wrong direction | Data may be arriving in descending order — confirm `createTimeSeriesData` sorts ascending by `x` |
