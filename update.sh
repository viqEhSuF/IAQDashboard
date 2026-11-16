#!/bin/bash
# Checks for upstream changes and rebuilds only what changed.
# Intended to be run by the iaq-update systemd timer once per day.

REPO_DIR="$(cd "$(dirname "$0")" && pwd)"
STAMP="[iaq-update $(date '+%Y-%m-%d %H:%M:%S')]"

# Add Go and Bun to PATH — both may be absent from the systemd environment.
export PATH=$PATH:/usr/local/go/bin
for d in /home/*/.bun/bin /root/.bun/bin; do
  [ -d "$d" ] && export PATH=$PATH:$d
done

cd "$REPO_DIR"

# Follow the branch this copy was cloned on (v2 for systems on the new
# database schema, main for older systems).
BRANCH=$(git rev-parse --abbrev-ref HEAD)
if [ "$BRANCH" = "HEAD" ]; then
  echo "$STAMP Not on a branch (detached HEAD) — skipping update."
  exit 1
fi

echo "$STAMP Checking for updates on $BRANCH..."
if ! git fetch origin "$BRANCH" 2>&1; then
  echo "$STAMP git fetch failed — skipping update."
  exit 1
fi

LOCAL=$(git rev-parse HEAD)
REMOTE=$(git rev-parse "origin/$BRANCH")

if [ "$LOCAL" = "$REMOTE" ]; then
  echo "$STAMP Already up to date."
  exit 0
fi

echo "$STAMP Updates found — applying..."

API_CHANGED=$(git diff --name-only "HEAD..origin/$BRANCH" | grep -c '^sensor-api/' || true)
FRONTEND_CHANGED=$(git diff --name-only "HEAD..origin/$BRANCH" | grep -c '^sensor-dashboard/' || true)
INGEST_CHANGED=$(git diff --name-only "HEAD..origin/$BRANCH" | grep -c '^ingest/iaq_ingest.php' || true)

git pull origin "$BRANCH"

# The ingest script's settings live in /etc/iaq/config.php and are not touched
if [ "$INGEST_CHANGED" -gt 0 ]; then
  if cp "$REPO_DIR/ingest/iaq_ingest.php" /var/www/html/iaq_ingest.php; then
    echo "$STAMP Ingest script updated."
  else
    echo "$STAMP Ingest script copy failed."
  fi
fi

if [ "$API_CHANGED" -gt 0 ]; then
  echo "$STAMP Building Go API..."
  cd "$REPO_DIR/sensor-api"
  if go build -o sensor-api .; then
    systemctl stop sensor-api
    cp sensor-api /usr/local/bin/sensor-api
    systemctl start sensor-api
    echo "$STAMP API updated and restarted."
  else
    echo "$STAMP API build failed — leaving existing binary in place."
  fi
fi

if [ "$FRONTEND_CHANGED" -gt 0 ]; then
  # The build needs about 1.5 GB of memory. On a 1 GB Pi it runs out and
  # stalls the whole system, so skip it there; deploy a build made on another
  # computer instead (DEPLOYMENT.md, section 6).
  MEM_KB=$(awk '/^MemTotal:/ {print $2}' /proc/meminfo)
  if [ "${MEM_KB:-0}" -lt 1500000 ]; then
    echo "$STAMP Frontend changed, but this Pi has too little memory to build it."
    echo "$STAMP Build it on another computer and copy it in (DEPLOYMENT.md, section 6)."
  else
    echo "$STAMP Building frontend..."
    cd "$REPO_DIR/sensor-dashboard"
    bun install
    if timeout 30m bun run build; then
      cp -r build/* /var/www/html/
      echo "$STAMP Frontend deployed."
    else
      echo "$STAMP Frontend build failed or timed out — leaving existing files in place."
    fi
  fi
fi

echo "$STAMP Done."
