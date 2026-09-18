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
