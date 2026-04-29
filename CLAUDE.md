# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Purpose

Automated deployment of a hybrid sing-box proxy server on Debian/Ubuntu. Sets up Trojan (TCP:443) and Hysteria2 (UDP:8443) inbounds with URLTest-based failover between an ISP SOCKS5 exit and the VPS's native IP. Client subscriptions are hosted on Cloudflare Pages.

## Common Commands

```bash
# Full deployment
sudo ./install.sh

# Force reinstall sing-box package
sudo ./install.sh --force-reinstall

# Skip UFW firewall configuration
sudo ./install.sh --skip-firewall

# Interactive management menu (status, logs, restart, backup, uninstall)
./manage.sh

# Validate sing-box config syntax
sing-box check -c /etc/sing-box/config.json

# Check service status / follow logs
systemctl status sing-box
journalctl -u sing-box -f

# Manual Cloudflare Pages subscription deploy
cd cloudflare-pages-sub && wrangler pages deploy .

# Test SOCKS5 exit IP
curl --socks5 USER:PASS@HOST:PORT https://ipinfo.io/ip

# Test subscription endpoints
curl -s https://<pages-domain>/v  # v2rayN
curl -s https://<pages-domain>/c  # Clash
```

## Architecture

```
Client (v2rayN / Clash)
    │
    ├── Trojan TCP:443  (tj.<domain>)
    └── Hysteria2 UDP:8443  (hy2.<domain>)
              │
         sing-box server
       /etc/sing-box/config.json
              │
         URLTest (every 3 min against gstatic 204)
              │
    ┌─────────┴─────────┐
    │                   │
isp-out               direct-out
(1024proxy SOCKS5)    (VPS native IP)
```

**Inbounds**: Two protocols share the same outbound logic via `egress-auto` URLTest selector.

**Certificates**: Auto-provisioned via Let's Encrypt with Cloudflare DNS-01 challenge; stored in `/var/lib/sing-box/certmagic/`.

**Subscriptions**: Cloudflare Pages Functions (`cloudflare-pages-sub/functions/`) serve:
- `/v` — Base64-encoded v2rayN URI list
- `/c` — Full Clash YAML (geo-routing, DNS, 30+ streaming service rules)
- `_redirects` masks real paths behind short URLs

## Key Files

| File | Role |
|------|------|
| `install.sh` | Main deployment script (~1350 lines); parses `.env`, generates and deploys `/etc/sing-box/config.json` via `jq`, configures UFW, manages systemd, deploys Cloudflare Pages subscriptions |
| `manage.sh` | Post-deploy management menu: status, logs, restart, IP tests, config check, backup, uninstall |
| `.env` / `.env.example` | All runtime configuration (domains, ports, credentials, Cloudflare tokens, URLTest params); parsed without `source` to avoid side effects |
| `cloudflare-pages-sub/functions/v2.js` | Cloudflare Pages Function: returns v2rayN subscription |
| `cloudflare-pages-sub/functions/c.js` | Cloudflare Pages Function: returns Clash YAML subscription |
| `cloudflare-pages-sub/wrangler.toml` | Cloudflare Pages project config |
| `nodes.yaml` | Reference node definitions for manual client setup |

## Configuration

`.env` must be populated before running `install.sh`. Key variables:

- `TROJAN_DOMAIN` / `HYSTERIA_DOMAIN` — Cloudflare-proxied DNS entries
- `CF_API_TOKEN` — Cloudflare DNS:Edit token for ACME challenge
- `SOCKS5_*` — 1024proxy ISP egress credentials
- `TROJAN_PASSWORD` / `HYSTERIA_PASSWORD` — auto-generate with `openssl rand -base64 32`
- `CF_PAGES_API_TOKEN` / `CF_ACCOUNT_ID` — for `wrangler pages deploy`
- `URLTEST_INTERVAL` / `URLTEST_TOLERANCE` — failover tuning (defaults: 3m / 100ms)

**Constraint**: The `.env` parser does not support inline comments — values must not contain `#`.

## install.sh Internals

- Config JSON is built with `jq -n` (not string templating), so variables are safely embedded.
- UFW rules are added incrementally — existing rules are not reset.
- Cloudflare Pages Functions (`v2.js`, `c.js`) are generated dynamically at deploy time with actual credential values injected.
- Subscription verification retries 3 times before issuing a warning (not a hard failure).
- On config deployment failure, the previous config is restored from a timestamped backup.
- `--no-start` flag installs without starting the service (useful in CI/test contexts).

## Runtime Paths

| Path | Contents |
|------|----------|
| `/etc/sing-box/config.json` | Active sing-box configuration (mode 600) |
| `/var/lib/sing-box/certmagic/` | ACME certificates (mode 700) |
| `/etc/apt/sources.list.d/sagernet.sources` | Official sing-box APT repo |
| `client-info.txt` | Generated client connection strings |
| `deploy-summary.txt` | Last deployment status |
