# lintux-modkit

Shared Go packages for the Lintux modules for ZimaOS (ZFW, Cron, Sync & Backup):

| Package | What |
|---|---|
| `auth` | ZimaOS session-token verifier (ES256 against the platform JWKS, resolved through the gateway route table), HTTP middleware |
| `notify` | Webhook (generic, n8n, Discord, Slack, Home Assistant, Uptime Kuma), e-mail and Telegram delivery |
| `schedule` | 5-field cron validation and next-run computation with one shared alias table |
| `watchdog` | Boot watchdog and binary-refresh units in `/etc/systemd/system` for sysext services |
| `httpx` | JSON errors with stable codes, same-origin CSRF check, request logging, static UI fallback |

Everything here was measured on ZimaOS 1.7.x; the comments carry the measurements.

```sh
go test -race ./...
```

Apache License 2.0.

## Installing the modules

Two ready-made installers, pick the one you want — each installs what is
missing and updates what is old, nothing else, no switches needed:

```sh
# Cron + Sync & Backup, no firewall
curl -fsSL https://raw.githubusercontent.com/chicohaager/lintux-modkit/main/install-without-firewall.sh -o /tmp/lintux-install.sh
sudo bash /tmp/lintux-install.sh

# ZFW Firewall + Cron + Sync & Backup
curl -fsSL https://raw.githubusercontent.com/chicohaager/lintux-modkit/main/install-with-firewall.sh -o /tmp/lintux-install.sh
sudo bash /tmp/lintux-install.sh
```

Run the same script again any time to update. `--check` only reports,
`--force` reinstalls even when up to date.

Both are generated from `install.sh` (`tools/gen-installers.sh`; CI fails
when they are stale). `install.sh` itself is the flexible form: by default
it updates whatever is installed and adds nothing; `--install zbackup`
(or `cron`, `zfw`, `all`) adds a module, `--only cron,zbackup` restricts
the run.

For each module it reads the version the running daemon reports (health
route behind the gateway, no login), the latest release tag from the GitHub
API, downloads the asset for this CPU (amd64/arm64), verifies the sha256 the
release ships, and installs — zfw through its own `install.sh`, cron and
zbackup through `zpkg` (an installed module is removed first; jobs, history
and keys under `/DATA/AppData/<module>` are kept). A zbackup with a running
job is left alone unless `--force` is given. Exit code 0 when everything
wanted is current, 1 when a module was skipped.

Verified on ZimaOS 1.7.1 (amd64): both ready-made installers (the
no-firewall one bringing back a removed Sync & Backup, the full one on a
current host), `--check`, `--force` over all three modules, and `install.sh`
leaving a removed module alone until `--install` names it.
