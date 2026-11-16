# Changelog

Modules pin lintux-modkit by tag and commit (`lintux-modkit.ref`, `<tag> <commit>`).
Before raising a pin, read the **Breaking** lines of every version in between.
`tools/find-consumers.sh` lists the public repositories that use lintux-modkit and the version each pins.

## v0.1.6 — 2026-11-16

**Breaking**

- `appdata.Secure` and `sysext/appdata-guard.sh` follow a symlink on the way only when root owns it, and then check
  the path behind it up to `/`. Before, a symlinked ancestor was passed through `stat` without asking who owns the
  link or what lies behind it. A path whose ancestor is a symlink of another user, or points under an unsafe
  directory, is now refused; a module on such a path stops with a message naming the link.

Other changes

- `appdata`: `/DATA` owned by another user (uid 999, the login user, on a ZimaOS 1.8 box) is given back to root
  instead of refused; the mode stays, the log names the old owner and the way back (`chown <uid>:<gid> /DATA`).
  A symlinked `/DATA` and an unsafe mode are still refused. Before, every module with the guard stopped on such a box.
- `appdata`: a symlinked parent (`/DATA/AppData` moved to another disk) is followed one step to a real path instead
  of refused as "not a real directory"; "missing" and "not a directory" are told apart. Repeated and trailing slashes
  in a link target do not count as further symlinks; `.` and `..` still do.
- `appdata`: adding the sticky bit keeps setgid/setuid (as `chmod +t`).
- `sysext/modkit-check.sh` and `tools/modkit-pins.sh`: the modules' pin check lives here; a module's copy is checked
  against it, and `tools/modkit-pins.sh` sets a pin in one step.
- No other API change; moving from v0.1.5 needs nothing else unless a module runs from a path with a symlink of
  another user.

## v0.1.5 — 2026-11-16

Other changes

- `sysext/bundle-debian.sh`: Debian snapshot `20261116T155657Z` (was `20261020T213255Z`) and `debian:trixie` 13.7
  (index digest `sha256:9c6e3814…`, was `4c252754…`). With the old snapshot every build stopped with rc=3, because the
  live mirror had a security update (`zlib1g 1:1.3.dfsg+really1.3.1-1+deb13u1`).
- `sysext/bundle-debian.sh`: upgrades the packages the image already has to the snapshot before installing. Before,
  a package that came with the image (here `zlib1g`) stayed at the image's version whatever the snapshot, so a newer
  snapshot could not clear the stale-package stop.
- No API change; moving from v0.1.4 needs nothing else.

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
