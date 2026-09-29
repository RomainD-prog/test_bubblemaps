#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUNTIME_DIR="$ROOT_DIR/.runtime"
LOG_FILE="$RUNTIME_DIR/cloudflared.log"
CLOUDFLARED_BIN="$(mise which cloudflared 2>/dev/null || command -v cloudflared)"

mkdir -p "$RUNTIME_DIR"
launchctl bootout "gui/$(id -u)/com.bubblemaps.cloudflared" 2>/dev/null || true
tmux kill-session -t bubblemaps-cloudflared 2>/dev/null || true
: > "$LOG_FILE"
tmux new-session -d -s bubblemaps-cloudflared \
  "$CLOUDFLARED_BIN --config /dev/null tunnel --url http://localhost:8080 --no-autoupdate 2>&1 | tee '$LOG_FILE'"

PUBLIC_URL=""
for _ in {1..30}; do
  PUBLIC_URL="$(
    awk 'match($0, /https:\/\/[a-z0-9-]+\.trycloudflare\.com/) {
      print substr($0, RSTART, RLENGTH); exit
    }' "$LOG_FILE"
  )"
  [[ -n "$PUBLIC_URL" ]] && break
  sleep 1
done

if [[ -z "$PUBLIC_URL" ]]; then
  echo "Cloudflare did not return a public URL." >&2
  cat "$LOG_FILE" >&2
  exit 1
fi

printf '%s\n' "$PUBLIC_URL" > "$RUNTIME_DIR/public-url"
printf '%s\n' "$PUBLIC_URL"
