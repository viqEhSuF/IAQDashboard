#!/bin/bash
# Brings this system up to date with its branch on GitHub and installs what
# changed: the API, the dashboard and the ingest script.
#
# The iaq-update timer runs it once a day as root. By hand:
#   sudo bash ~/IAQDashboard/update.sh                    install what changed
#   sudo bash ~/IAQDashboard/update.sh --all              rebuild and reinstall everything
#   sudo bash ~/IAQDashboard/update.sh --frontend-copied  record a dashboard built on
#                                                         another computer as installed
#
# Each part is recorded as installed (in /var/lib/iaq-update) only once its
# build and install succeed, so a part that failed is tried again on the next
# run even when there is nothing new to pull. Git and the builds run as the
# owner of this folder, so no root-owned files end up in it.

set -uo pipefail

REPO_DIR="$(cd "$(dirname "$0")" && pwd)"
STATE_DIR=${IAQ_STATE_DIR:-/var/lib/iaq-update}
WEB_ROOT=${IAQ_WEB_ROOT:-/var/www/html}
API_BIN=${IAQ_API_BIN:-/usr/local/bin/sensor-api}
STAMP="[iaq-update $(date '+%Y-%m-%d %H:%M:%S')]"
say() { echo "$STAMP $*"; }

if [ "$(id -u)" -ne 0 ]; then
  echo "Run this with sudo: sudo bash $0" >&2
  echo "It installs into $WEB_ROOT and restarts the API, which needs root." >&2
  exit 1
fi

FORCE=0
FRONTEND_COPIED=0
for arg in "$@"; do
  case "$arg" in
    --all) FORCE=1 ;;
    --frontend-copied) FRONTEND_COPIED=1 ;;
    *) echo "Unknown option: $arg" >&2; exit 1 ;;
  esac
done

# Git and the builds run as the folder's owner, with Go and Bun on the PATH
OWNER=$(stat -c %U "$REPO_DIR")
OWNER_HOME=$(getent passwd "$OWNER" | cut -d: -f6)
BUILD_PATH="/usr/local/go/bin:$OWNER_HOME/.bun/bin:$OWNER_HOME/go/bin:/usr/local/bin:/usr/bin:/bin"
as_owner() {
  if [ "$OWNER" = root ]; then
    env PATH="$BUILD_PATH" "$@"
  else
    runuser -u "$OWNER" -- env HOME="$OWNER_HOME" PATH="$BUILD_PATH" "$@"
  fi
}

cd "$REPO_DIR"

# Earlier versions ran git and the builds as root; hand anything they left
# back to the owner so git and bun can write to it again
if [ "$OWNER" != root ] && [ -n "$(find "$REPO_DIR" -xdev ! -user "$OWNER" -print -quit)" ]; then
  say "Returning root-owned files in $REPO_DIR to $OWNER."
  chown -R "$OWNER": "$REPO_DIR"
fi

mkdir -p "$STATE_DIR"

if [ "$FRONTEND_COPIED" = 1 ]; then
  as_owner git rev-parse HEAD > "$STATE_DIR/frontend"
  say "Recorded the dashboard as installed at $(cut -c1-7 "$STATE_DIR/frontend")."
  exit 0
fi

# Follow the branch this copy is on (v2 for systems on the new database
# schema, main for older ones)
BRANCH=$(as_owner git rev-parse --abbrev-ref HEAD)
if [ -z "$BRANCH" ] || [ "$BRANCH" = "HEAD" ]; then
  say "Not on a branch — skipping update."
  exit 1
fi

say "Checking for updates on $BRANCH..."
if ! as_owner git fetch origin "$BRANCH"; then
  say "git fetch failed — skipping update."
  exit 1
fi
if [ "$(as_owner git rev-parse HEAD)" != "$(as_owner git rev-parse "origin/$BRANCH")" ]; then
  say "Updates found — pulling..."
  if ! as_owner git pull --ff-only origin "$BRANCH"; then
    say "git pull failed, so nothing was installed. 'git status' in $REPO_DIR shows what's in the way."
    exit 1
  fi
else
  say "Code is up to date."
fi
HEAD_NOW=$(as_owner git rev-parse HEAD)

# needs_install PART PATH...: true if PATH changed since PART was last
# installed, or it never was (or --all)
needs_install() {
  local part=$1 last
  shift
  [ "$FORCE" = 1 ] && return 0
  last=$(cat "$STATE_DIR/$part" 2>/dev/null || true)
  [ -z "$last" ] && return 0
  as_owner git cat-file -e "$last^{commit}" 2>/dev/null || return 0
  [ -n "$(as_owner git diff --name-only "$last" "$HEAD_NOW" -- "$@")" ]
}
installed() { echo "$HEAD_NOW" > "$STATE_DIR/$1"; }

FAILED=0

# The ingest script's settings live in /etc/iaq/config.php and are not touched
if needs_install ingest ingest/iaq_ingest.php; then
  if cp "$REPO_DIR/ingest/iaq_ingest.php" "$WEB_ROOT/iaq_ingest.php"; then
    installed ingest
    say "Ingest script installed."
  else
    say "Ingest script copy failed."
    FAILED=1
  fi
fi

if needs_install api sensor-api; then
  say "Building the API..."
  if (cd "$REPO_DIR/sensor-api" && as_owner go build -o sensor-api .); then
    systemctl stop sensor-api
    if cp "$REPO_DIR/sensor-api/sensor-api" "$API_BIN"; then
      installed api
      say "API installed."
    else
      say "API copy failed — the previous version is still in place."
      FAILED=1
    fi
    systemctl start sensor-api
    sleep 2
    systemctl is-active --quiet sensor-api || { say "The API service didn't start: journalctl -u sensor-api -n 20"; FAILED=1; }
  else
    say "API build failed — the running API is unchanged."
    FAILED=1
  fi
fi

if needs_install frontend sensor-dashboard; then
  # The build needs about 1.5 GB of memory. On a 1 GB Pi it runs out and
  # stalls the whole system, so skip it there; build it on another computer
  # and copy it in (DEPLOYMENT.md, section 6).
  MEM_KB=$(awk '/^MemTotal:/ {print $2}' /proc/meminfo)
  if [ "${MEM_KB:-0}" -lt 1500000 ]; then
    say "The dashboard changed, but this Pi has too little memory to build it."
    say "Build it on another computer and copy it in (DEPLOYMENT.md, section 6), then run:"
    say "  sudo bash $REPO_DIR/update.sh --frontend-copied"
  else
    say "Building the dashboard..."
    if (cd "$REPO_DIR/sensor-dashboard" && as_owner bun install && as_owner timeout 30m bun run build); then
      if cp -r "$REPO_DIR/sensor-dashboard/build/." "$WEB_ROOT/"; then
        installed frontend
        say "Dashboard installed. Reload any open dashboard pages to see it."
      else
        say "Dashboard copy failed."
        FAILED=1
      fi
    else
      say "Dashboard build failed or timed out — the installed dashboard is unchanged."
      FAILED=1
    fi
  fi
fi

if [ "$FAILED" = 1 ]; then
  say "Done, with failures. They'll be tried again on the next run."
  exit 1
fi
say "Done. Installed from $(echo "$HEAD_NOW" | cut -c1-7)."
