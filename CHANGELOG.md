# Changelog

Modules pin lintux-modkit by tag and commit (`lintux-modkit.ref`, `<tag> <commit>`).
Before raising a pin, read the **Breaking** lines of every version in between.
`tools/find-consumers.sh` lists the public repositories that use lintux-modkit and the version each pins.

## v0.1.4 — 2026-11-15

**Breaking**

- `auth`: `Verifier.Verify` accepts only a session whose `role` claim is exactly `"admin"`. Any other role
  (for example `"user"`, which IceDash measured for a ZimaOS sub-account), an empty role and a **missing** role claim are
  refused with `ErrNotAdmin`; `Verifier.Middleware` answers them with 403 `auth_forbidden`.
  - A module that lets non-admin accounts in (read-only views, per-user pages) stops working for them.
  - A module that runs the verifier on CasaOS refuses everyone: a CasaOS 0.4.15 token carries no `role` (measured by IceDash, `internal/session/session.go`).
  - Such a module stays on v0.1.3.

Other changes

- `webmod`: `Options.MaxBody` caps POST/PUT bodies per module (0 keeps the 1 MiB default); `Server` is exported for tests and dev servers.
- `web/common.js`: describes the 403 `auth_forbidden` answer.
- Docs and examples no longer carry addresses of the maintainer's network.

## v0.1.3 — 2026-10-27

- `tools/hosttest-lib.sh`: host tests clean up after a failure or abort.
- `webmod`: `/health` reports a replaced binary.
- `stale.Find`.

## v0.1.2 — 2026-10-26

- Appdata guard: `appdata.Secure`, `sysext/appdata-guard.sh --no-create`, `webmod` `DataDirs`.
- Image file modes 755/644 whatever the umask of the build.
- `tools/check-release.sh`.

## v0.1.1 — 2026-10-26

- `auth` finds the JWKS through `user-service.url` (written by root only), not through the gateway route table, which a process without root can change.

## v0.1.0 — 2026-10-26

First tag: `auth`, `gateway`, `httpx`, `notify`, `schedule`, `stale`, `watchdog`, `web`, `webmod`, `ysk` and the sysext tools.
