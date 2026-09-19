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

## Installing the modules — `install.sh`

One script installs or updates the whole stack on a ZimaOS host — ZFW
Firewall, Cron and Sync & Backup — from their GitHub releases:

```sh
curl -fsSL https://raw.githubusercontent.com/chicohaager/lintux-modkit/main/install.sh -o /tmp/lintux-install.sh
sudo bash /tmp/lintux-install.sh                    # update the modules that are installed
sudo bash /tmp/lintux-install.sh --install zbackup  # also install this one (cron, zbackup, zfw or all)
sudo bash /tmp/lintux-install.sh --check            # report only: installed vs. latest
sudo bash /tmp/lintux-install.sh --only cron,zbackup
sudo bash /tmp/lintux-install.sh --force            # reinstall even when up to date
```

Without `--install` it never adds a module you do not have — not everyone
wants a firewall, and a firewall nobody asked for can lock people out; a
missing module is reported with the switch that would add it.

For each module it reads the version the running daemon reports (health
route behind the gateway, no login), the latest release tag from the GitHub
API, downloads the asset for this CPU (amd64/arm64), verifies the sha256 the
release ships, and installs — zfw through its own `install.sh`, cron and
zbackup through `zpkg` (an installed module is removed first; jobs, history
and keys under `/DATA/AppData/<module>` are kept). A zbackup with a running
job is left alone unless `--force` is given. Exit code 0 when everything
wanted is current, 1 when a module was skipped.

Verified on ZimaOS 1.7.1 (amd64): `--check` on a current host, `--force` over
all three modules, a default run that leaves a removed module alone, and
`--install zbackup` bringing it back.
