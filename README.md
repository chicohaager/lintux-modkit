# lintux-modkit

Shared Go packages for the Lintux modules for ZimaOS (ZFW, Cron, Sync & Backup):

| Package | What |
|---|---|
| `auth` | ZimaOS session-token verifier (ES256 against the platform JWKS, resolved through the gateway route table), HTTP middleware |
| `notify` | Webhook (generic, n8n, Discord, Slack, Home Assistant, Uptime Kuma), e-mail and Telegram delivery |
| `schedule` | 5-field cron validation and next-run computation with one shared alias table |
| `watchdog` | Boot watchdog and binary-refresh units in `/etc/systemd/system` for sysext services; `Uninstall` removes exactly those four units again |
| `httpx` | JSON errors with stable codes, same-origin CSRF check, request logging, static UI fallback |

Everything here was measured on ZimaOS 1.7.x; the comments carry the measurements.

## sysext build kit (`sysext/`)

One build and one lint for every module instead of a hand-written `build.sh` per repository.

| Script | What |
|---|---|
| `sysext/build-sysext.sh <name> <rootfs> <amd64\|arm64> <out>` | Builds from a copy of `<rootfs>` (the source stays untouched), writes `extension-release.<name>` with `ID=_any` and `ARCHITECTURE` (`x86-64`/`arm64`), squashfs gzip, `-all-root`, reproducible via `SOURCE_DATE_EPOCH` (default: last commit). Emits `<name>-<arch>.raw` + `.sha256`, and for amd64 also `<name>.raw` — the name `zpkg` fetches from the latest release for a `repo` catalog entry (measured 2026-10-02: `zima_cron.raw` 404, `cron.raw` 200). Runs the lint first; an ERROR aborts the build. |
| `sysext/lint-units.sh <rootfs> [installer.sh …]` | ERROR: a unit uses `/DATA` without `RequiresMountsFor=/DATA/…`; `StartLimitIntervalSec`/`StartLimitBurst` outside `[Unit]`; an installer runs `systemctl enable --now <x>.service` (an upgrade then keeps the old binary). WARN: `WantedBy=multi-user.target` inside a sysext (not started at boot — needs `watchdog`); `extension-release` without `ARCHITECTURE`. |
| `sysext/uninstall-watchdog.sh <service>` | Shell counterpart of `watchdog.Uninstall` for uninstall scripts. |

Run against the units and installers as they stood before 2026-10-02, the lint reports exactly the three faults found by hand that day (zfw-ui and zima-vm-extras without `RequiresMountsFor`, vm-extras installer with `enable --now`).

Still required on ZimaOS 1.8.0-beta1: the boot watchdog. A sysext with `EXTENSION_RELOAD_MANAGER=1` and a shipped `multi-user.target.wants/` link was not started at boot either (measured with a reboot, 2026-10-02).

```sh
bash tools/test-sysext.sh   # 21 cases, each rule against a case that must fire and one that must not
```

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
`--force` reinstalls even when up to date. A development build
(`0.3.0-dev7`) counts as older than its release (`0.3.0`), so the release
replaces it without `--force` (`tools/test-semver.sh`).

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
