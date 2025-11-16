#!/usr/bin/env bash
set -euo pipefail

APP_DIR="/opt/log4shell/log4shell-vulnerable-app"
LOG_FILE="/opt/log4shell/vulnerable-app-native.log"

if pgrep -f "log4shell-vulnerable-app-0.0.1-SNAPSHOT.jar" >/dev/null 2>&1; then
  echo "[=] Vulnerable app already running."
  exit 0
fi

cd "$APP_DIR"

if ! ls build/libs/log4shell-vulnerable-app-*-SNAPSHOT.jar >/dev/null 2>&1; then
  echo "[*] Building vulnerable app JAR..."
  chmod +x gradlew
  ./gradlew clean build
fi

JAR="$(ls build/libs/log4shell-vulnerable-app-*-SNAPSHOT.jar | grep -v plain | head -n1)"

if [ -z "$JAR" ]; then
  echo "[-] Could not find built JAR in build/libs/" >&2
  exit 1
fi

echo "[*] Using JAR: $JAR"
echo "[*] Starting vulnerable app on port 8080 ..."
nohup java -jar "$JAR" >"$LOG_FILE" 2>&1 &

echo "[*] Logs: $LOG_FILE"
