# CLAUDE.md

This file describes the current repository contract for coding agents.

## Purpose

Deploy one Debian/Ubuntu sing-box ingress server with deterministic ISP SOCKS5 egress. Every unexpired TSV entry receives one Trojan/TCP inbound, one Hysteria2/UDP inbound, and independent v2rayN/Clash subscriptions.

The retired J server is out of scope. Never add, contact, or deploy to J.

## Safety invariants

- An inbound for ISP `id` must route normal and AI traffic only to `isp-out-id`.
- Do not add automatic cross-ISP or public-VPS fallback.
- Keep `route.final=block`.
- Public direct egress is allowed only for explicit `DIRECT_BULK_*` rules.
- `.env`, `isp-list.tsv`, generated subscriptions, and migration bundles contain secrets and must never enter Git.
- Preserve TSV row order because it determines stable ingress ports.
- Homepage hiding is presentation only, not authorization.

## Common commands

```bash
sudo ./install.sh
sudo ./install.sh --force-reinstall
sudo ./install.sh --skip-firewall
sudo ./install.sh --skip-network-tuning
sudo ./install.sh --no-start
./install.sh --validate-only
sudo ./manage.sh

sing-box check -c /etc/sing-box/config.json
systemctl status sing-box
journalctl -u sing-box -f

./migrate.sh export
./migrate.sh import /path/to/migration-*.tar.gz.enc
```

## Architecture

```text
v2rayN / v2rayNG / Clash / Mihomo
             |
       Trojan or Hysteria2
             |
       T sing-box ingress
             |
   matching ISP SOCKS5 egress
```

Each ISP row produces:

- `trojan-<id>-in` and `hy2-<id>-in`
- `isp-out-<id>`
- `T-<id>-TJ` and `T-<id>-HY2`
- `/v2?isp=<id>` and `/c?isp=<id>`

## Performance contract

- `HYSTERIA_CC_MODE=bbr` is the default: generated Hysteria2 clients omit fixed up/down values and the server ignores client bandwidth declarations.
- `HYSTERIA_CC_MODE=brutal` emits configured up/down values.
- Linux tuning is managed in `/etc/sysctl.d/99-sing-box-performance.conf`.
- The default UDP receive/send maximum is 16 MiB.
- Linux TCP BBR + `fq` are enabled when the kernel supports them.
- TCP Fast Open is applied to Trojan listen fields and ISP SOCKS dial fields.

## Key files

| File | Role |
| --- | --- |
| `install.sh` | Safe env parsing, validation, sing-box JSON generation, network/UFW/systemd setup, Pages asset generation and deployment |
| `manage.sh` | Status, logs, egress checks, backups, encrypted migration export, uninstall |
| `migrate.sh` | AES-256-CBC/PBKDF2 export and validated import of `.env` plus ISP TSV |
| `.env.example` | Non-secret configuration reference |
| `isp-list.example.tsv` | Field-only private inventory example |
| `sync-clash-rules.sh` | Atomic rule snapshot validation and Pages redeploy |
| `cloudflare-pages-sub/index.html` | Public subscription entry page |

Pages assets under `cloudflare-pages-sub/functions/`, `subscriptions.json`, `global-extension.js`, and rule snapshots are generated or refreshed by the deployment flow.

## Subscription endpoints

- `/v2` and `/v2?isp=<id>`: Base64 v2rayN/v2rayNG subscriptions
- `/c` and `/c?isp=<id>`: Clash/Mihomo YAML
- `/s`: Clash Verge/Mihomo global extension

Single-ISP responses expose a stable profile name through `Profile-Title` and `Content-Disposition`, with a 24-hour profile update interval.

## Validation expectations

Before deployment:

```bash
bash -n install.sh manage.sh migrate.sh sync-clash-rules.sh
git diff --check
```

On the server, additionally validate:

```bash
sing-box check -c /etc/sing-box/config.json
systemctl is-active sing-box
sysctl net.core.rmem_max net.core.wmem_max
sysctl net.ipv4.tcp_congestion_control net.core.default_qdisc net.ipv4.tcp_fastopen
```

Test both TCP and UDP ingress, every active ISP SOCKS5 exit, subscription response headers, YAML parsing, and the fixed-ingress-to-fixed-egress invariant.
