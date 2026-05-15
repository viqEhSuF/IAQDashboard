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

# Service runs as root; git refuses to operate on a repo owned by another user
# unless the directory is explicitly marked safe.
git config --global --add safe.directory "$REPO_DIR" 2>/dev/null || true

echo "$STAMP Checking for updates..."
if ! git fetch origin main 2>&1; then
  echo "$STAMP git fetch failed — skipping update."
  exit 1
fi

LOCAL=$(git rev-parse HEAD)
REMOTE=$(git rev-parse origin/main)

if [ "$LOCAL" = "$REMOTE" ]; then
  echo "$STAMP Already up to date."
  exit 0
fi

echo "$STAMP Updates found — applying..."

API_CHANGED=$(git diff --name-only HEAD..origin/main | grep -c '^sensor-api/' || true)
FRONTEND_CHANGED=$(git diff --name-only HEAD..origin/main | grep -c '^sensor-dashboard/' || true)

git pull origin main

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
  echo "$STAMP Building frontend..."
  cd "$REPO_DIR/sensor-dashboard"
  bun install
  if bun run build; then
    cp -r build/* /var/www/html/
    echo "$STAMP Frontend deployed."
  else
    echo "$STAMP Frontend build failed — leaving existing files in place."
  fi
fi

echo "$STAMP Done."
