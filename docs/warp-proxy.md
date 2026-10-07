# Cloudflare WARP as a SOCKS5 proxy in Docker

Docker container that runs the Cloudflare WARP client and exposes it as a local SOCKS5 proxy. Only the traffic of applications configured to
use the proxy goes through Cloudflare; the host routing is not modified.

---

## 1. Concepts

| Term                | Definition                                                                                                                                                    |
|---------------------|---------------------------------------------------------------------------------------------------------------------------------------------------------------|
| **WARP**            | Cloudflare client (`warp-svc` and `warp-cli`) that establishes an encrypted tunnel between the device and the Cloudflare network.                             |
| **Consumer mode**   | WARP with a personal account: Free, or WARP+ through a license key. Use case: browsing through Cloudflare.                                                    |
| **Zero Trust mode** | WARP enrolled in a Cloudflare Zero Trust organization. Applies the organization policies and provides access to its private network (internal web, Git, SSH). |
| **Registration**    | Device identity in Cloudflare (account, keys). Stored in `reg.json` and `conf.json`.                                                                          |
| **Kill switch**     | Firewall rule that prevents proxy traffic from leaving through any path other than the WARP tunnel.                                                           |

Both modes use the same image and the same `entrypoint.sh`. They differ in the `WARP_MODE` variable, the registration directory and the
port:

|                     | Consumer                 | Zero Trust                                           |
|---------------------|--------------------------|------------------------------------------------------|
| Compose service     | `consumer`               | `zerotrust`                                          |
| Container           | `warp-proxy`             | `warp-proxy-zerotrust`                               |
| `WARP_MODE`         | `consumer`               | `zerotrust`                                          |
| Registration        | `data/consumer/`         | `data/zerotrust/`                                    |
| Proxy               | `127.0.0.1:1080`         | `127.0.0.1:1081`                                     |
| Registration method | Automatic on first start | Manual: SSO login and token                          |
| Start               | `docker compose up -d`   | `docker compose --profile zerotrust up -d zerotrust` |

---

## 2. Architecture

```
 Host                                Container
+------------------+                +-----------------------------------+
| Browser / SSH    |     SOCKS5     | microsocks :1080 (user "socks")   |
| 127.0.0.1:1080   | -------------> |                 |                 |
+------------------+                |                 v                 |
                                    |      kill switch (nftables)       |
                                    |                 |                 |
 Other traffic                      |                 v                 |
 --> ISP (unchanged)                |   CloudflareWARP interface (tun)  |
                                    |                 |                 |
                                    |                 v                 |
                                    |             warp-svc              |
                                    +-----------------|-----------------+
                                                      |
                                                      v
                                                 Cloudflare
                                                      |
                                                      v
                                         Internet / private network
```

- `warp-svc` creates the tunnel in the container network namespace, not in the host one.
- `microsocks` accepts SOCKS5 connections and forwards them through the tunnel. It runs as the unprivileged user `socks`.
- Kill switch: the `socks` user can only send traffic through the `CloudflareWARP` interface. If WARP disconnects, proxy connections fail
  instead of leaving through the ISP. Docker's embedded DNS (`127.0.0.11`) is also blocked.
- If `warp-svc` or `microsocks` exits, the container exits and Docker restarts it (`restart: unless-stopped`).
- The port is published on `127.0.0.1` only: the proxy is not reachable from other machines on the network.

---

## 3. Requirements

- Docker Desktop (Windows/macOS) or Docker Engine (Linux).
- Git for Windows, for `connect.exe`. Only needed for SSH from Windows (section 7.3).

---

## 4. Structure

```
warp-proxy/
├── Dockerfile
├── entrypoint.sh
├── compose.yaml
├── .dockerignore
├── .gitattributes
├── .gitignore
├── docs/
│   └── warp-proxy.md
└── data/                    # created on first start
    ├── consumer/            # consumer mode registration
    └── zerotrust/           # Zero Trust mode registration
```

`data/` contains the device credentials. It is the only directory that requires backup (section 9) and must not be published.

---

## 5. Files

`entrypoint.sh` requires LF line endings. With CRLF the container fails with `/bin/bash^M: bad interpreter`.

### 5.1 `Dockerfile`

```dockerfile
FROM ubuntu:24.04

ARG WARP_VERSION=""

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && \
    apt-get install -y --no-install-recommends ca-certificates curl gnupg dbus iproute2 nftables microsocks && \
    curl -fsSL https://pkg.cloudflareclient.com/pubkey.gpg | gpg --yes --dearmor --output /usr/share/keyrings/cloudflare-warp-archive-keyring.gpg && \
    echo "deb [signed-by=/usr/share/keyrings/cloudflare-warp-archive-keyring.gpg] https://pkg.cloudflareclient.com/ noble main" > /etc/apt/sources.list.d/cloudflare-client.list && \
    apt-get update && \
    apt-get install -y --no-install-recommends "cloudflare-warp${WARP_VERSION:+=$WARP_VERSION}" && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/* && \
    useradd --system --no-create-home --shell /usr/sbin/nologin socks

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

EXPOSE 1080

HEALTHCHECK --interval=60s --timeout=15s --start-period=60s --retries=3 \
    CMD curl -fsS --max-time 10 --socks5-hostname 127.0.0.1:1080 https://www.cloudflare.com/cdn-cgi/trace | grep -q '^warp=on'

ENTRYPOINT ["/entrypoint.sh"]
```

| Element                | Purpose                                                                        |
|------------------------|--------------------------------------------------------------------------------|
| `ARG WARP_VERSION`     | `cloudflare-warp` version. Empty = latest available. Example: `2026.7.1377.0`. |
| `dbus`                 | Required by `warp-svc`.                                                        |
| `nftables`, `iproute2` | Kill switch and tunnel interface management.                                   |
| `microsocks`           | SOCKS5 server.                                                                 |
| `socks` user           | Unprivileged user that runs the proxy and is subject to the kill switch.       |
| `HEALTHCHECK`          | Verifies every 60 s that proxy traffic goes through WARP (`warp=on`).          |

### 5.2 `entrypoint.sh`

```bash
#!/bin/bash
set -euo pipefail

LISTEN_PORT=1080

# consumer: creates a consumer (Free) registration if none exists.
# zerotrust: waits for the organization registration to be injected (token).
WARP_MODE="${WARP_MODE:-consumer}"

case "$WARP_MODE" in
    consumer|zerotrust) ;;
    *) echo "Invalid WARP_MODE: '$WARP_MODE' (use consumer or zerotrust)" >&2; exit 1 ;;
esac

# Kill switch: the "socks" user can only send traffic through the WARP tunnel.
# If WARP goes down, its connections are dropped instead of leaving through eth0.
# Docker's embedded DNS is also blocked to prevent DNS leaks.
nft -f - <<NFT
table inet warp_proxy_killswitch {
    chain output {
        type filter hook output priority -10; policy accept;
        # Replies to clients connected to the proxy (they arrive through eth0)
        meta skuid "socks" ct direction reply accept
        meta skuid "socks" ip daddr 127.0.0.11 drop
        meta skuid "socks" oifname != { "lo", "CloudflareWARP" } drop
    }
}
NFT

# D-Bus (required by warp-svc)
mkdir -p /run/dbus
rm -f /run/dbus/pid
dbus-daemon --config-file=/usr/share/dbus-1/system.conf

# WARP daemon (it already writes its logs to /var/lib/cloudflare-warp)
warp-svc --accept-tos >/dev/null 2>&1 &
WARP_PID=$!

for _ in $(seq 1 30); do
    warp-cli --accept-tos status >/dev/null 2>&1 && break
    sleep 1
done

if ! warp-cli --accept-tos registration show >/dev/null 2>&1; then
    if [ "$WARP_MODE" = "consumer" ]; then
        echo "No registration found, creating a new one..."
        warp-cli --accept-tos registration new
    else
        echo "No registration found. Waiting for manual registration (warp-cli registration token ...)"
        until warp-cli --accept-tos registration show >/dev/null 2>&1; do
            sleep 5
        done
        echo "Registration detected"
    fi
fi

# In Zero Trust the organization may enforce the mode; a rejection is not an error
warp-cli --accept-tos mode warp || echo "Notice: the mode is managed by the organization"
warp-cli --accept-tos connect

for _ in $(seq 1 60); do
    warp-cli --accept-tos status | grep -q "Connected" && break
    sleep 1
done
warp-cli --accept-tos status

# Unprivileged SOCKS5 server (subject to the kill switch)
setpriv --reuid=socks --regid=socks --clear-groups microsocks -i 0.0.0.0 -p "$LISTEN_PORT" >/dev/null 2>&1 &
SOCKS_PID=$!

wait -n "$WARP_PID" "$SOCKS_PID"
exit 1
```

Startup sequence:

1. Validates `WARP_MODE`.
2. Loads the kill switch, before any connection exists.
3. Starts `dbus` and `warp-svc`, and waits for the daemon to respond.
4. Without a registration: `consumer` creates a Free one; `zerotrust` waits until the token is injected.
5. Enables tunnel mode, connects and waits for the `Connected` state.
6. Starts `microsocks` as the `socks` user.
7. If `warp-svc` or `microsocks` exits, the script exits with code 1 and Docker restarts the container.

### 5.3 `compose.yaml`

```yaml
x-warp-proxy: &warp-proxy
  build:
    context: .
    args:
      WARP_VERSION: ""
  image: warp-proxy:latest
  restart: unless-stopped
  init: true
  cap_add:
    - NET_ADMIN
  devices:
    - /dev/net/tun:/dev/net/tun
  logging:
    driver: json-file
    options:
      max-size: "10m"
      max-file: "3"

services:
  consumer:
    <<: *warp-proxy
    container_name: warp-proxy
    environment:
      WARP_MODE: consumer
    ports:
      - "127.0.0.1:1080:1080"
    volumes:
      - ./data/consumer:/var/lib/cloudflare-warp

  zerotrust:
    <<: *warp-proxy
    profiles: [ "zerotrust" ]
    container_name: warp-proxy-zerotrust
    environment:
      WARP_MODE: zerotrust
    ports:
      - "127.0.0.1:1081:1080"
    volumes:
      - ./data/zerotrust:/var/lib/cloudflare-warp
    # Internal domains without public DNS (name:IP)
    # extra_hosts:
    #   - "git.internal.example:10.0.0.10"
```

| Element                              | Purpose                                                                                        |
|--------------------------------------|------------------------------------------------------------------------------------------------|
| `x-warp-proxy`                       | Settings shared by both services (YAML anchor merged with `<<: *warp-proxy`).                  |
| `cap_add: NET_ADMIN`, `/dev/net/tun` | Required to create the tunnel and apply the kill switch.                                       |
| `profiles: ["zerotrust"]`            | The `zerotrust` service only starts when the profile is explicitly requested.                  |
| `ports: 127.0.0.1:…`                 | Local access only. `"1080:1080"` would expose it to the whole network, without authentication. |
| `extra_hosts`                        | Static resolution of internal domains without public DNS (Zero Trust mode).                    |
| `logging`                            | Docker log rotation: 3 files of 10 MB.                                                         |

### 5.4 `.dockerignore`

```
# Ignore everything and allow only what the Dockerfile uses
*
!entrypoint.sh
```

Allowlist: excludes everything from the build context except `entrypoint.sh`, the only file copied by the `Dockerfile`. Files or directories
added to the project (for example `data/`, which holds credentials) stay out of the image without changing this file. If the `Dockerfile`
gets a new `COPY`, the copied file must be added with `!<path>`.

### 5.5 `.gitattributes`

```
* text=auto eol=lf
```

Enforces LF line endings in the repository files.

### 5.6 `.gitignore`

```
# WARP registrations (device credentials)
data/
```

---

## 6. Installation

Commands run from the project directory.

### 6.1 Consumer mode

```bash
docker compose up -d --build
```

A Free registration is created in `data/consumer/` on first start. If the directory already contains a registration, it is reused.

```bash
docker exec warp-proxy warp-cli --accept-tos registration show   # Account type: Free
docker exec warp-proxy warp-cli --accept-tos status              # Status update: Connected
```

#### WARP+ (optional)

The license key is obtained in the 1.1.1.1 app (iOS/Android) with an active WARP+ subscription: **Settings → Account → Key**.

1. Write down the current key (`License:` line); it is required to revert the change:

   ```bash
   docker exec warp-proxy warp-cli --accept-tos registration show
   ```

2. Apply the new key:

   ```bash
   docker exec warp-proxy warp-cli --accept-tos registration license <LICENSE_KEY>
   ```

3. Verify: the account type is no longer `Free` and the trace (section 8) shows `warp=plus`.

- The key binding happens on Cloudflare servers. Restoring `data/consumer/` does not revert it; to revert, apply the key noted in step 1.
- `Too many devices`: the key reached its device limit.
- The key is accepted but the account stays `Free`: the key has no WARP+ quota. Keys from the WARP+ referral program (ended on 2024-11-01)
  fall into this case.

### 6.2 Zero Trust mode

**1. Internal domains (optional).** In `compose.yaml`, uncomment `extra_hosts` in the `zerotrust` service and add `name:IP` entries.

**2. Start the service.**

```bash
docker compose --profile zerotrust up -d --build zerotrust
docker logs warp-proxy-zerotrust     # "Waiting for manual registration..."
```

Without a registration, the proxy does not forward traffic.

**3. Obtain the token.**

1. In a browser on the host, open `https://<team-name>.cloudflareaccess.com/warp`.
2. Complete the organization SSO login.
3. Cancel the browser dialog that asks to open the WARP application.
4. On the confirmation page, inspect the button that opens WARP and copy the value of its `href` attribute, which starts with
   `com.cloudflare.warp://`.

**4. Inject the token** right after obtaining it, since it expires:

```bash
docker exec warp-proxy-zerotrust warp-cli --accept-tos registration token "com.cloudflare.warp://<...>"
```

The container detects the registration, connects and starts the proxy.

```bash
docker logs warp-proxy-zerotrust                                          # "Registration detected" … "Connected"
docker exec warp-proxy-zerotrust warp-cli --accept-tos registration show  # organization
docker exec warp-proxy-zerotrust warp-cli --accept-tos status             # Status update: Connected
```

**Considerations:**

- The kill switch only allows traffic through the tunnel. Networks that the organization excludes from the tunnel (*split tunnels*) are not
  reachable through the proxy.
- If the organization enforces the connection mode, the mode change is ignored and a notice is logged.
- Re-authentication when the Access session expires:

  ```bash
  docker exec warp-proxy-zerotrust warp-cli --accept-tos debug access-reauth
  ```

#### Migrating an existing installation

An existing Zero Trust registration is reused without repeating the token:

1. Stop the previous container: `docker stop <previous-container>`.
2. Copy the contents of its data directory (the one mounted at `/var/lib/cloudflare-warp`) to `data/zerotrust/`.
3. Remove the previous container: `docker rm <previous-container>`.
4. `docker compose --profile zerotrust up -d --build zerotrust`.
5. Verify that `registration show` displays the same ID as before.
6. Update the port in the clients (browser, `~/.ssh/config`) to `1081`.

### 6.3 Both modes on the same host

```bash
docker compose --profile zerotrust up -d --build
```

Consumer on `127.0.0.1:1080` and Zero Trust on `127.0.0.1:1081`, each with its own registration.

---

## 7. Client configuration

The examples use port 1080 (consumer). Zero Trust uses port 1081.

### 7.1 Firefox

1. **Settings → General → Network Settings → Settings…**
2. **Manual proxy configuration.**
3. **SOCKS Host:** `127.0.0.1`. **Port:** `1080`. **SOCKS v5**.
4. HTTP/HTTPS fields empty.
5. Enable **Proxy DNS when using SOCKS v5**. Without this option, DNS queries go through the ISP and `extra_hosts` domains are not resolved.

### 7.2 curl

```bash
curl --socks5-hostname 127.0.0.1:1080 https://example.com
```

`--socks5-hostname` resolves DNS through the proxy; `--socks5` resolves it locally. On Windows the executable is `curl.exe`.

### 7.3 SSH

`HostKeyAlgorithms` and `PubkeyAcceptedAlgorithms` are only needed for servers that use legacy algorithms (`ssh-rsa`, `ssh-dss`).

**Linux / macOS** (OpenBSD `nc`):

```bash
ssh -o ProxyCommand="nc -X 5 -x 127.0.0.1:1081 %h %p" \
    -o HostKeyAlgorithms=+ssh-rsa,ssh-dss \
    -o PubkeyAcceptedAlgorithms=+ssh-rsa \
    user@<server-ip>
```

**Windows (PowerShell)**, with `connect.exe` from Git for Windows:

```powershell
ssh -o 'ProxyCommand="C:\Program Files\Git\mingw64\bin\connect.exe" -S 127.0.0.1:1081 %h %p' `
    -o HostKeyAlgorithms=+ssh-rsa,ssh-dss `
    -o PubkeyAcceptedAlgorithms=+ssh-rsa `
    user@<server-ip>
```

**Persistent configuration** in `~/.ssh/config` (Linux/macOS) or `C:\Users\<user>\.ssh\config` (Windows):

```
# Linux / macOS
Match host 10.0.0.*,*.internal.example
    ProxyCommand nc -X 5 -x 127.0.0.1:1081 %h %p
    HostKeyAlgorithms +ssh-rsa,ssh-dss
    PubkeyAcceptedAlgorithms +ssh-rsa
```

```
# Windows
Match host 10.0.0.*,*.internal.example
    ProxyCommand "C:\Program Files\Git\mingw64\bin\connect.exe" -S 127.0.0.1:1081 %h %p
    HostKeyAlgorithms +ssh-rsa,ssh-dss
    PubkeyAcceptedAlgorithms +ssh-rsa
```

With this configuration: `ssh user@<server-ip>`.

**Verification without connecting** (`ssh -G` prints the effective configuration for a host):

```powershell
ssh -G <server-ip> | Select-String "proxycommand|hostkeyalgorithms"   # must include the ProxyCommand
ssh -G github.com  | Select-String "proxycommand"                     # empty: direct connection
```

**File transfers** (`scp`, `sftp`, `rsync` over SSH) use the same `ProxyCommand`:

```bash
scp -o ProxyCommand="nc -X 5 -x 127.0.0.1:1081 %h %p" ./file user@<server-ip>:/path/
```

Windows OpenSSH is very slow for bulk transfers whenever a `ProxyCommand` is used, regardless of the helper (`connect.exe`, `ncat`).
Interactive sessions are not noticeably affected. OpenSSH on Linux (including WSL) with `nc` does not show this behavior.

**Keepalives.** `ServerAliveInterval` and `ServerAliveCountMax` (e.g. `-o ServerAliveInterval=30 -o ServerAliveCountMax=6`) make the client
send keepalives through the encrypted channel and detect a dead connection. They help when idle sessions are dropped or when an intermediate
hop (proxy, NAT, tunnel reconnection) leaves a connection hung (`Broken pipe`, `Connection reset`). They do not resume an interrupted
transfer; `rsync --partial` and `sftp reput` can.

### 7.4 Git

| URL type                                | Proxy applied                                             |
|-----------------------------------------|-----------------------------------------------------------|
| SSH (`git@<host>:group/repo.git`)       | The one in `~/.ssh/config` (7.3). No extra configuration. |
| HTTPS (`https://<host>/group/repo.git`) | Requires Git's own configuration.                         |

HTTPS proxy scoped to one host:

```bash
git config --global http.https://<host>.proxy socks5h://127.0.0.1:1081
```

`socks5h` resolves DNS through the proxy.

### 7.5 Database clients and other applications

Applications with SOCKS5 support (DBeaver, DataGrip, etc.) are configured in the connection proxy settings: type `SOCKS5`, host `127.0.0.1`,
port `1081`. The database host is the internal IP.

### 7.6 Testing a TCP port

```powershell
curl.exe -v --max-time 10 --socks5-hostname 127.0.0.1:1081 telnet://<ip>:<port>
```

- Connection established and waiting: the port is reachable (exit with `Ctrl+C`).
- Timeout or SOCKS error: destination not included in the tunnel, no route, or port closed (section 11).

For HTTP services: `curl.exe --socks5-hostname 127.0.0.1:1081 http://<ip>:<port>`.

---

## 8. Verification

Commands for consumer mode. For Zero Trust: container `warp-proxy-zerotrust` and port `1081`.

| # | Check               | Command                                                                          | Expected result                                                       |
|---|---------------------|----------------------------------------------------------------------------------|-----------------------------------------------------------------------|
| 1 | Registration        | `docker exec warp-proxy warp-cli --accept-tos registration show`                 | Expected ID and account type. After a restore, the same ID as before. |
| 2 | Connection          | `docker exec warp-proxy warp-cli --accept-tos status`                            | `Connected`, `Network: healthy`                                       |
| 3 | Health              | `docker ps`                                                                      | `(healthy)` 1-2 min after start                                       |
| 4 | Egress through WARP | `curl --socks5-hostname 127.0.0.1:1080 https://www.cloudflare.com/cdn-cgi/trace` | `warp=on` or `warp=plus`                                              |
| 5 | Host unchanged      | `curl https://www.cloudflare.com/cdn-cgi/trace`                                  | `warp=off`, ISP IP                                                    |
| 6 | Kill switch         | `docker exec warp-proxy warp-cli --accept-tos disconnect`, then repeat #4        | #4 fails. It must never return the ISP IP.                            |
| 7 | Reconnection        | `docker exec warp-proxy warp-cli --accept-tos connect`, then repeat #4           | `warp=on`                                                             |

In the configured browser, `https://www.cloudflare.com/cdn-cgi/trace` must show `warp=on`.

**Additional checks in Zero Trust mode:**

| Check                                        | Command                                                                                   | Expected result                                                                                       |
|----------------------------------------------|-------------------------------------------------------------------------------------------|-------------------------------------------------------------------------------------------------------|
| Configuration received from the organization | `docker exec warp-proxy-zerotrust warp-cli --accept-tos settings`                         | `Organization`, split tunnel mode (`Include mode` / `Exclude mode`) with its IP list, tunnel protocol |
| Destinations routed through the tunnel       | `docker exec warp-proxy-zerotrust warp-cli --accept-tos settings \| Select-String "<ip>"` | The IP (or a range containing it) appears in the `Include mode` list                                  |
| Tunnel routing table                         | `docker exec warp-proxy-zerotrust warp-cli --accept-tos tunnel dump`                      | In Include mode it lists what is **excluded** (long list); the short list is in `settings`            |
| Access to an internal service                | Section 7.6                                                                               | Connection established                                                                                |

---

## 9. Backup and restore

Back up the whole project directory, including `data/`.

| File                         | Contents                                       |
|------------------------------|------------------------------------------------|
| `reg.json`                   | Registration: device ID, account and keys      |
| `conf.json`, `settings.json` | Configuration associated with the registration |
| `cfwarp_*.txt`               | WARP logs. No backup needed.                   |

**Restore on a new host:**

1. Install Docker.
2. Copy the project directory including `data/`.
3. Start the corresponding service (section 6).
4. Verify (section 8). Check #1 must show the same ID.

**Restore without `data/`:**

- Consumer: a new Free registration is created. With WARP+, the license key must be applied again.
- Zero Trust: the token must be obtained and injected again.

---

## 10. Operations

```bash
# Status and logs
docker ps
docker logs warp-proxy
docker exec warp-proxy warp-cli --accept-tos status

# Restart / stop / start
docker compose restart
docker compose stop
docker compose start

# Update WARP to the latest version (the registration is kept)
docker compose build --no-cache
docker compose up -d

# Installed version
docker exec warp-proxy dpkg-query -W cloudflare-warp
```

For Zero Trust, add `--profile zerotrust` to the `docker compose` commands.

Detailed WARP logs are stored in `data/<mode>/cfwarp_service_log.txt`, with automatic rotation.

---

## 11. Troubleshooting

| Symptom                                                                                            | Cause                                                                                                                                       | Solution                                                                                                                                                         |
|----------------------------------------------------------------------------------------------------|---------------------------------------------------------------------------------------------------------------------------------------------|------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| The proxy does not respond                                                                         | WARP disconnected (blocked by the kill switch) or the container is restarting                                                               | `docker logs` and `warp-cli status`; then `warp-cli connect` or `docker compose restart`                                                                         |
| `/bin/bash^M: bad interpreter`                                                                     | `entrypoint.sh` with CRLF line endings                                                                                                      | Convert to LF and rebuild                                                                                                                                        |
| `Invalid WARP_MODE`                                                                                | Value other than `consumer` or `zerotrust`                                                                                                  | Fix `environment` in `compose.yaml`                                                                                                                              |
| Registration with an unexpected ID                                                                 | `data/<mode>/` empty or not mounted                                                                                                         | Stop, restore `data/<mode>/` and start                                                                                                                           |
| Zero Trust: "Waiting for manual registration"                                                      | Token not injected                                                                                                                          | Section 6.2, steps 3 and 4                                                                                                                                       |
| Zero Trust: internal domain does not resolve                                                       | Proxy DNS disabled in the client, or domain missing from `extra_hosts`                                                                      | Enable the option (7.1) or add the entry and run `docker compose --profile zerotrust up -d zerotrust`                                                            |
| Zero Trust: internal IP unreachable                                                                | The IP is not in the profile Include list, has no route in the organization, or the `cloudflared` server cannot reach it                    | `warp-cli settings` (section 8); review routes and split tunnels in the Zero Trust dashboard                                                                     |
| Large transfers stall or connections hang after the handshake, while small requests work           | The path MTU to the WARP endpoint is smaller than the tunnel packets (for example, another VPN client on the host lowers the interface MTU) | Check the path MTU (section 11.1). Try the other tunnel protocol: `warp-cli tunnel protocol set MASQUE\|WireGuard` (consumer) or the device profile (Zero Trust) |
| `scp`/`sftp` from Windows very slow through the proxy                                              | Windows OpenSSH performs poorly with any `ProxyCommand`                                                                                     | Section 7.3                                                                                                                                                      |
| `error gathering device information ... "C"` with `docker run --device /dev/net/tun` from Git Bash | Git Bash rewrites the `/dev/net/tun` path                                                                                                   | Prefix the command with `MSYS_NO_PATHCONV=1` or use `docker compose`                                                                                             |
| 403 responses or captchas on some sites                                                            | Those sites restrict WARP IPs                                                                                                               | Not caused by the proxy; access them without the proxy                                                                                                           |
| Occasional high latency                                                                            | WARP Free network congestion                                                                                                                | Inherent to the Free plan                                                                                                                                        |

### 11.1 Performance diagnostics

Commands to locate where a slow transfer is limited. `<container>` is `warp-proxy` or `warp-proxy-zerotrust`; inside the container the proxy
always listens on port 1080.

| Check                         | Command                                                                                   | What it shows                                                                                                                                                                                                                      |
|-------------------------------|-------------------------------------------------------------------------------------------|------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| Tunnel health                 | `docker exec <container> warp-cli --accept-tos tunnel stats`                              | Protocol, WARP endpoint IPs (`Endpoints`), latency and estimated loss                                                                                                                                                              |
| Tunnel MTU                    | `docker exec <container> ip link show CloudflareWARP`                                     | MTU of the tunnel interface                                                                                                                                                                                                        |
| Proxy → destination           | `docker exec <container> ss -tin dst <server-ip>`                                         | RTT, `cwnd`, peer receive window (`snd_wnd`), retransmissions, limiting flags                                                                                                                                                      |
| Client → proxy                | `docker exec <container> ss -tin sport :1080`                                             | How data arrives from the client application                                                                                                                                                                                       |
| Path MTU to the WARP endpoint | Linux: `ping -M do -s <size> <endpoint-ip>`<br>Windows: `ping -f -l <size> <endpoint-ip>` | Largest packet that reaches the endpoint without fragmentation (packet = `<size>` + 28 bytes). The result is also capped by the MTU of the interface the ping leaves from (host, VM or WSL); a limit below that MTU is on the path |

Reading `ss -tin` on the proxy → destination connection:

| Observation                               | Meaning                                                                                                           |
|-------------------------------------------|-------------------------------------------------------------------------------------------------------------------|
| `app_limited` and low `notsent`           | The proxy is waiting for data: the limit is before the proxy (client application or how it connects to the proxy) |
| `rwnd_limited` or small `snd_wnd`         | The destination limits the transfer (receive window)                                                              |
| High `retrans`, or loss in `tunnel stats` | Network or MTU problems on the tunnel path                                                                        |

The throughput of one connection is the difference in `bytes_acked` (sending) or `bytes_received` (receiving) between two samples, divided
by the seconds between them.

---

## 12. Design decisions and limitations

| Decision                                                                               | Reason                                                                                                                                                              |
|----------------------------------------------------------------------------------------|---------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| WARP tunnel + `microsocks` instead of WARP's native proxy mode (`warp-cli mode proxy`) | The native proxy mode has noticeably lower throughput (≈1.5 MB/s vs ≈4 MB/s, also with parallel connections) and cannot reach IPv6-only destinations.               |
| Tunnel protocol not forced                                                             | The protocol (MASQUE or WireGuard) is the one assigned by Cloudflare (consumer) or by the device profile (Zero Trust). `warp-cli settings` shows it and its origin. |
| Per-user kill switch (`meta skuid`)                                                    | Covers IPv4 and IPv6 without depending on the addresses assigned by WARP.                                                                                           |
| One image for both modes                                                               | The difference between modes is limited to the registration; the rest of the code is shared.                                                                        |

**Limitations:**

- TCP only. `microsocks` does not forward UDP. Browsing through SOCKS does not use UDP.
- No proxy authentication; hence it is published on `127.0.0.1` only.
- ≈290 MB compressed image: `cloudflare-warp` depends on graphics libraries (webkit2gtk, llvm) that cannot be omitted.
- Requires `NET_ADMIN` and `/dev/net/tun`.
