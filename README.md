# lintux-modkit

Shared Go packages for the Lintux modules for ZimaOS (ZFW, Cron, Sync & Backup), and one installer for those plus mergerfs + SnapRAID and Tailscale:

| Package | What |
|---|---|
| `auth` | ZimaOS session-token verifier (ES256 against the platform JWKS, found through `user-service.url`, which only root writes — the gateway route table only on systems without that file: a process without root can change the table), HTTP middleware |
| `notify` | Webhook (generic, n8n, Discord, Slack, Home Assistant, Uptime Kuma), e-mail and Telegram delivery |
| `schedule` | 5-field cron validation and next-run computation with one shared alias table |
| `watchdog` | Boot watchdog and binary-refresh units in `/etc/systemd/system` for sysext services; `Uninstall` removes exactly those four units again |
| `httpx` | JSON errors with stable codes, same-origin CSRF check, request logging, static UI fallback |

Everything here was measured on ZimaOS 1.7.x; the comments carry the measurements.

## sysext build kit (`sysext/`)

One build and one lint for every module instead of a hand-written `build.sh` per repository.

| Script | What |
|---|---|
| `sysext/build-sysext.sh <name> <rootfs> <amd64\|arm64> <out> [version]` | Builds from a copy of `<rootfs>` (the source stays untouched), writes `extension-release.<name>` with `ID=_any`, `ARCHITECTURE` (`x86-64`/`arm64`) and, when `[version]` is given, `SYSEXT_VERSION_ID` (a leading `v` is dropped; the Module Manager reads the installed version from it), squashfs gzip, `-all-root`, reproducible via `SOURCE_DATE_EPOCH` (default: last commit). Emits `<name>-<arch>.raw` + `.sha256`, and for amd64 also `<name>.raw` — the name `zpkg` fetches from the latest release for a `repo` catalog entry (measured 2026-10-02: `zima_cron.raw` 404, `cron.raw` 200). Writes the lintux-modkit commit it ran from to `usr/share/doc/<name>/lintux-modkit.txt` (`+dirty` for a changed copy, `unbekannt` outside git): to rebuild a release, check out that commit next to the module. Runs the lint first; an ERROR aborts the build. Warns when `usr/share/casaos/modules/<name>.json` is missing: without it `zpkg install` merges the image but answers "module not installed" with rc=1 (measured 1.8.0). |
| `sysext/lint-units.sh <rootfs> [installer.sh …]` | ERROR: a unit uses `/DATA` without `RequiresMountsFor=/DATA/…`; `StartLimitIntervalSec`/`StartLimitBurst` outside `[Unit]`; an installer runs `systemctl enable --now <x>.service` (an upgrade then keeps the old binary). WARN: `WantedBy=multi-user.target` inside a sysext (not started at boot — needs `watchdog`), unless the `ExecStart` binary contains `lintux-modkit/watchdog.Install` (the symbol survives `-s -w`); `extension-release` without `ARCHITECTURE`. |
| `sysext/uninstall-watchdog.sh <service>` | Shell counterpart of `watchdog.Uninstall` for uninstall scripts. |
| `sysext/unit-watchdog.sh enable\|disable\|status <unit> [delay]` | Boot watchdog for modules without their own Go binary (bundled third-party programs, template instances such as `wireguard@wg0.service`): writes `<base>-watchdog.{service,timer}` to `/etc/systemd/system` (`@` becomes `-`, `OnBootSec` default 15), enables the timer and (re)starts the unit; `disable` reverses it. No refresh path unit: after `zpkg install --force` `PathChanged` did not fire (measured 1.8.0). |
| `sysext/bundle-debian.sh <name> <rootfs> <amd64\|arm64> "<packages>" <program>…` | Puts programs from Debian 13 (image pinned by digest) into a sysext root: programs at their own path, their libraries in `usr/lib/<name>/` with RPATH, never replacing a host library (measured on 1.8.0: no host process loaded one); refuses a program needing a glibc above `GLIBC_MAX` (2.41; ZimaOS 1.8.0 has 2.42); writes `usr/share/doc/<name>/packages.txt` and each package's `copyright`. A program at a path the host already has would still replace the host's file — check the image's file list on the host first. |
| `sysext/add-web.sh <name> <rootfs> <version>` | For a module with a dashboard tile: copies `web/common.js` and `web/styles.css` into `usr/share/casaos/www/modules/<name>/`, puts the version into the HTML (cache-busting) and turns `usr/share/casaos/modules/<name>.json.in` into the module JSON, then checks every `.js` with `node --check` and the JSON's name. |
| `webmod` (Go) | The backend frame of a tile: boot watchdog, loopback listener, gateway route with retries, session-token check, CSRF, static UI, `<route>/health`; `Options.Restart` names the module's own daemons for `stale`. Used by the admintools, wireguard, nebula, restic, node-exporter and pangolin modules. |
| `ysk` (Go) | A card on the ZimaOS dashboard through the message bus (YSK, "You should know"): `NewCard` in the form 1.8.0 renders (one button that opens a URL), `Notifier.Show`/`Withdraw`, bus address only on loopback. Cards are not stored by ZimaOS — re-send them while the reason lasts. Used by Sync & Backup and the Module Manager. |
| `stale` (Go) | Restarts units still running the binary of a replaced module image: a module update (`zpkg remove` + `install`) restarts only the services of the module JSON, its daemons kept the old binary (measured 1.8.0). Compares the sha256 of `/proc/<pid>/exe` with the `ExecStart` binary — not the path: every `zpkg install` re-mounts `/usr`, so all module processes show a detached path (`/bin/node_exporter`) even when unchanged. |
| `web/common.js`, `web/styles.css` | Shared front end of the tiles: API calls with the ZimaOS token and its refresh, theme, and `zfw` — open a UDP port in the ZFW firewall from the browser (save, apply, commit; no safe-apply, whose dead-man would remove the whole firewall if the commit failed). |

Run against the units and installers as they stood before 2026-10-02, the lint reports exactly the three faults found by hand that day (zfw-ui and zima-vm-extras without `RequiresMountsFor`, vm-extras installer with `enable --now`).

Still required on ZimaOS 1.8.0-beta1: the boot watchdog. A sysext with `EXTENSION_RELOAD_MANAGER=1` and a shipped `multi-user.target.wants/` link was not started at boot either (measured with a reboot, 2026-10-02).

```sh
bash tools/test-sysext.sh   # 21 cases, each rule against a case that must fire and one that must not
```

```sh
go test -race ./...
```

MIT License, see [LICENSE](LICENSE).

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
(or `cron`, `zfw`, `mergerfs`, `tailscale`, `all`) adds a module,
`--only cron,zbackup` restricts the run. mergerfs + SnapRAID and Tailscale
are in neither ready-made installer — they come, and update, only when named.

For each module it reads the installed version, the latest release tag
(from the `/releases/latest` redirect, which has no API quota; the GitHub
API only as fallback), downloads the asset for this CPU (amd64/arm64),
verifies the sha256 the release ships, and installs:

| Module | Installed version from | Installed through | Left alone while |
|---|---|---|---|
| `zfw` | health route behind the gateway | its own `install.sh` (tarball) | — |
| `cron`, `zbackup` | health route behind the gateway | `zpkg` (installed module removed first; data under `/DATA/AppData/<module>` kept) | zbackup: a job runs |
| `mergerfs` | sha256 of `mergerfs-snapraid.raw` against the release's `SHA256SUMS` | its `install.sh` from the release's source archive (`pool.env`, `snapraid.conf` kept) | `snapraid` runs |
| `tailscale` | module: `SYSEXT_VERSION_ID`, Tailscale: `TAILSCALE_VERSION` in the merged extension-release (from module 1.0.4; else `tailscale version`) | its `install.sh` from the source archive, building the image on the host with the newest stable Tailscale (login state kept) | an SSH session comes in over the tailnet — the restart would cut it |

mergerfs and Tailscale change only when the run names them — `--install
tailscale` or `--only tailscale` — also when they are installed already: a
Tailscale update restarts `tailscaled` (the tailnet drops for ~2 s), a mergerfs
update swaps the image under a mounted pool. A plain run reports "update
available" and leaves them; the two ready-made installers never look at them.
`--force` overrides the other "left alone" cases, but does not name a module. Only the mergerfs update waits for a running `snapraid`; the other modules' `systemd-sysext refresh` under a running sync did no harm in a measurement on ZimaOS 1.8.0 (sync exit 0, `check` "Everything OK" — one sample).

Tailscale is kept current without new module releases: the installer reads
the newest stable version from `pkgs.tailscale.com` and has the module's
`build.sh` build the image on the host (`mksquashfs` ships with ZimaOS;
`build.sh` checks the tarball against the sha256 Tailscale publishes). An
installed Tailscale behind that version counts as an update — applied, like
every Tailscale update, only when the run names it. `TAILSCALE_VERSION=x.y.z`
pins a version. When the build cannot run (no `mksquashfs`, Tailscale
unreachable, a failed build) it falls back to the image in the module release.
A scheduled CI rebuild was the other way, and the weaker one: GitHub disables
schedules in a public repository after 60 days without activity.
Tailscale runs last (`tools/test-decisions.sh`: 16 cases of what a run installs). Exit code 0 when everything wanted is current, 1 when a
module was skipped.

Verified on ZimaOS 1.7.1 (amd64): both ready-made installers (the
no-firewall one bringing back a removed Sync & Backup, the full one on a
current host), `--check`, `--force` over all three modules, and `install.sh`
leaving a removed module alone until `--install` names it.

Verified on ZimaOS 1.8.0 (amd64), 2026-10-17: `--check` over all five
modules; mergerfs replaced by the v1.0.1 release on `--install` (a foreign
image left alone without it, the mounted pool stayed up); tailscale 1.0.4
installed end-to-end from the release (login kept), then `up to date`; the
snapraid guard against a running `snapraid`; the tailnet guard true over a
tailnet SSH session and false over the LAN (`tools/test-tailnet.sh` for the
address ranges).

Verified on ZimaOS 1.8.0 (amd64), 2026-10-17, with the upstream build: a pin
to Tailscale 1.102.3 built on the host, a plain run then only reported the
update to 1.104.1, `--install tailscale` built 1.104.1, a pin to a version
that does not exist fell back to the release image; login state, the mergerfs
pool and 0 failed units after every step.
