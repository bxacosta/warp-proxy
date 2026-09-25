# warp-proxy

Cloudflare WARP client in Docker, exposed as a local SOCKS5 proxy. Only applications configured to use the proxy go through Cloudflare; the host routing is not modified.

## Features

- **Two modes:** consumer (WARP Free / WARP+) and Cloudflare Zero Trust (access to an organization's private network).
- **Kill switch:** if WARP disconnects, the proxy stops forwarding instead of leaking traffic through the ISP. DNS leaks are also blocked.
- **Local only:** published on `127.0.0.1`.
- **Self-healing:** the container restarts if `warp-svc` or the proxy exits, and a healthcheck verifies `warp=on`.
- **Persistent registration:** stored in `data/`, reused across rebuilds.

## Quick start

Consumer mode (`127.0.0.1:1080`):

```bash
docker compose up -d --build
curl --socks5-hostname 127.0.0.1:1080 https://www.cloudflare.com/cdn-cgi/trace   # warp=on
```

Zero Trust mode (`127.0.0.1:1081`):

```bash
docker compose --profile zerotrust up -d --build zerotrust
docker exec warp-proxy-zerotrust warp-cli --accept-tos registration token "com.cloudflare.warp://<...>"
```

The token is obtained from `https://<team-name>.cloudflareaccess.com/warp` after the SSO login. See the [documentation](docs/warp-proxy.md#62-zero-trust-mode).

## Client setup

Configure the application with a SOCKS5 proxy at `127.0.0.1:1080` (or `1081` for Zero Trust) and remote DNS resolution enabled (for example, "Proxy DNS when using SOCKS v5" in Firefox, or `socks5h://` in curl and Git).

## Documentation

[docs/warp-proxy.md](docs/warp-proxy.md): architecture, files, installation, client setup (browser, SSH, Git, databases), verification, backup, troubleshooting and design decisions.

## Requirements

Docker with support for `NET_ADMIN` and `/dev/net/tun` (Docker Desktop or Docker Engine on Linux).

## License

[MIT](LICENSE)
