# Operations

## Prerequisites

- Linux user `administrator` for live work; developers run as their own uids for paper.
- Docker group membership for hands-on work (`administrator`, `joe`, `websurfinmurf`).
- Bitwarden CLI (`bw`) installed for live recreate (master password attended).
- `start-gateway` launcher on PATH (lives at `~/projects/ib-launcher/start-gateway.sh`).

## Environment Variables

### Live gateway (`~/projects/mcp/ib-live/docker-compose.yml`)
| Name | Required | Source | Notes |
|---|---|---|---|
| `TWS_USERID` | yes | Bitwarden vault | Compose fails loud if unset (`${VAR:?…}`) |
| `TWS_PASSWORD` | yes | Bitwarden vault | Same |
| `VNC_SERVER_PASSWORD` | yes | Bitwarden vault | Same |
| `TRADING_MODE` | yes | compose literal | `live` |
| `API_PORT` | yes | compose literal | `4001` (internal) |
| `SOCAT_PORT` | yes | compose literal | `4003` (exposed alias) |
| `TZ` | yes | compose literal | `America/New_York` — DST-handled |
| `TIME_ZONE` | yes | compose literal | `America/New_York` — IB Gateway `jts.ini` Logon.TimeZone |
| `AUTO_RESTART_TIME` | yes | compose literal | `07:00 AM` ET — daily IBC re-auth window |
| `TWOFA_DEVICE` | yes | compose literal | `"IB Key"` — verbatim match on the IBKR radio button label |
| `EXISTING_SESSION_DETECTED_ACTION` | yes | compose literal | `primary` |
| `RELOGIN_AFTER_TWOFA_TIMEOUT` | yes | compose literal | `yes` |
| `TWOFA_TIMEOUT_ACTION` | yes | compose literal | `restart` |
| `SAVE_TWS_SETTINGS` | yes | compose literal | `"00:30 Every Day"` |

### Paper gateway (`~/projects/mcp/ib-paper/docker-compose.yml`)
- Mirrors most of the durability env (`AUTO_RESTART_TIME`, `EXISTING_SESSION_DETECTED_ACTION`, `RELOGIN_AFTER_TWOFA_TIMEOUT`, `SAVE_TWS_SETTINGS`).
- Paper does NOT have `TWOFA_DEVICE` set (paper accounts use a different 2FA flow).
- Secrets: `$HOME/projects/secrets/ibgateway-paper.env` (admin-managed).

## Build & Run

### Live
```bash
# Recreate (attended — Bitwarden master password)
CONFIRM_LIVE=yes start-gateway

# Bounce (env unchanged)
docker restart mcp-ib-gateway-live

# DO NOT run bare compose — it will fail loud on missing secrets, by design
cd ~/projects/mcp/ib-live && docker compose up -d   # ← will refuse
```

### Paper
```bash
cd ~/projects/mcp/ib-paper && docker compose up -d
docker restart mcp-ib-gateway-paper
```

### Legacy (DEPRECATED — do not use)
```bash
# DO NOT — would collide on :4001 with mcp-middleware, secrets file deleted
cd ~/projects/ibgateway && docker compose up -d
```

## Deploy

- No CI/CD on either stack — admin-only manual recreate flows.
- Image bumps: edit pin in respective compose, recreate.
- Live image bumps require re-verifying "Maintain & resubmit orders" toggle default (gnzsnz base may flip it). VNC via Guacamole + `vncdotool` is the headless verification path.

## Health Checks

### Live wrapper
```bash
docker run --rm --network mcp-ib-live-net curlimages/curl:8.10.1 \
  -sS --max-time 5 http://mcp-ib-live:8000/health
# Expect: {"status":"healthy","pool":{"pool_size":3,"workers_alive":N,...}}
```

- `workers_alive: 0` is normal at idle — workers spin up on demand.
- Docker healthcheck currently reports `unhealthy` for `mcp-ib-live`: the test runs `curl -f http://localhost:8000/health` but `curl` isn't installed in the wrapper image. Service itself is fine. [PLANNED] Add `curl` to wrapper Dockerfile.

### Paper wrapper
- Same probe pattern via `mcp-ib-paper-net`.
- `mcp-ib-paper` Docker healthcheck currently reports `healthy` (paper wrapper image happens to include `curl`).

### Gateway containers (paper + live)
- No healthcheck defined at the moment. [PLANNED] Add a cheap socat-port probe.

## 2FA flow (live)

1. IBC fires login → opens "Second Factor Authentication" dialog.
2. With `TWOFA_DEVICE="IB Key"` set: IBC auto-clicks the radio button — IBKR pushes to the IB Key app immediately. Without it: dialog parks on the device-selector and no push arrives (manual VNC click required).
3. Phone tap → IBC completes login (~10–20s end-to-end).
4. If tap missed: dialog times out after ~3 min, `RELOGIN_AFTER_TWOFA_TIMEOUT=yes` retries automatically; IBKR enforces a 4 min 55 sec cooldown after each failed attempt.
5. `AUTO_RESTART_TIME=07:00 AM` ET means the daily 2FA push fires when you're awake, not overnight (was 03:00 UTC = 23:00 EDT until 2026-06-06).

## Guacamole VNC into the live gateway

- VNC inside the live gateway is on `mcp-ib-gateway-live:5900`, NOT host-published.
- `guacd` joined `mcp-ib-live-net` so Guacamole can reach it (see security.md for the trust trade-off).
- Use for: confirming "Maintain & resubmit orders" toggle state; rare manual interventions if IBC parks on an unexpected dialog.

## Logs

- Promtail auto-discovers all containers under `mcp-ib-*` → Loki → Grafana.
- `docker logs --tail N mcp-ib-gateway-live` is the fastest hand path during a 2FA debug.
