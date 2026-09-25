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
