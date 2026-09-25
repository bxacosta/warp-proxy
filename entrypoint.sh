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
