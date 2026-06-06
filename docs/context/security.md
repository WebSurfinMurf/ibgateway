# Security

## Trust model

- **Live (`U15907310`, real money)** — reachable only by `administrator` via `docker exec` into `mcp-ib-live`. No host port publish. Wrapper joins `mcp-ib-live-net` only.
- **Paper** — reachable by any container on `mcp-net` / `traefik-net` via the wrapper. Trust at the network layer (LAN/VPN perimeter).
- **Autonomous AI agents (websurfinmurf)** — explicitly outside the live trust domain. See "Phase A breach fix" below.

## Credentials

| Stack | Storage | Items |
|---|---|---|
| Live | Bitwarden vault (admin master), org `ai-servicers`, collection `administrators` | `ib-gateway-live` (TWS_USERID + TWS_PASSWORD), `ib-gateway-live-vnc` (VNC_SERVER_PASSWORD) |
| Paper | `~/projects/secrets/ibgateway-paper.env` (admin-managed on disk) | `IB_USERNAME`, `IB_PASSWORD`, `VNC_SERVER_PASSWORD` |
| Legacy `ibgateway-standalone` (deprecated) | Referenced `~/projects/secrets/ibgateway.env` — DELETED 2026-06-03 | (gone) |

### Live credential lifecycle
- Attended start: `start-gateway` unlocks Bitwarden interactively (master password prompt on TTY).
- Compose uses shell-env pass-through with `${VAR:?…}` syntax — bare `docker compose up -d` fails loud.
- After recreate: secrets live ONLY in the running container's process environment. Nothing on disk.
- No secrets in env_file:, no secrets in image layers, no secrets in CI logs.

### Bitwarden master password handling
- **Never type into the Claude chat box** — the `!` prefix in Claude Code detaches stdin; the prompt prints to stderr but no input reaches `bw unlock`. Anything typed as a chat message lands in the transcript.
- Always run `CONFIRM_LIVE=yes start-gateway` from a real SSH/console terminal as `administrator`.

## Network perimeters

### Live (post-2026-06-03 hardening)
- `mcp-ib-gateway-live` + `mcp-ib-live` joined to `mcp-ib-live-net` ONLY.
- No `mcp-net` join (was a reach path from shared-bus containers).
- No `traefik-net` join (was a reach path from any TLS-routable client).
- No host port publish on either gateway or wrapper (was reachable from any host-local process).
- Gateway's internal API/VNC ports never published.
- `guacd` (Guacamole VNC proxy) also joined `mcp-ib-live-net` for emergency VNC. Accepted trade-off; see "Open residuals".

### Paper
- Joined to `mcp-ib-paper-net` + `mcp-net` + `traefik-net`. Open by design for shared-bus consumers.

## Phase A breach fix (2026-06-03)

Demonstrated reach: websurfinmurf's autonomous agent (`agents-cli-claude-websurfinmurf`, `webui-claude-websurfinmurf`) was mounting `/var/run/docker.sock` → could `docker run --network mcp-ib-live-net …` and reach the live wrapper directly. Closed by:

1. Removed `/var/run/docker.sock:/var/run/docker.sock:ro` volume mount from both containers.
2. Removed `group_add: ["127"]` (docker GID) from both containers.
3. Recreated both containers via project deploy scripts.
4. Restored AppArmor + sysctl to Ubuntu defaults (had been weakened chasing rootless — reverted).
5. Restored `websurfinmurf`, `joe` to `docker` group (hands-on dev workflows preserved; only the autonomous agent is constrained).

Validation matrix T1–T6 passed:
- T1 socket mount absent ✓
- T2 docker daemon API reach exit=7 (refused) ✓
- T3 docker CLI not installed (exit 127) ✓
- T4 mcp-net pivot to live wrapper exit=6 (DNS fails) ✓
- T5 proxy pivot exit=22 (no route) ✓
- T6 legit admin → wrapper `/health` returns healthy ✓

## Rootless docker — abandoned (see `~/projects/portainer/docs/no-rootless.md` for full POV)

Spent ~2 days attempting rootless under `administrator` uid to isolate live from the rootful daemon. Walled on AppArmor capability mediation + detach-netns + kernel 6.17 on Noble. Re-grounded: even if it had worked, host root owns the rootless socket, so it didn't bind against the actual threat (agent holding the rootful socket). The load-bearing fix was Phase A (the socket removal), not the daemon split. Rootless stays off this host.

## Open residuals

1. **`mcp-ib-paper` wrapper still mounts `/var/run/docker.sock`** for `/gateway/reconnect`. Tracked separately; paper is non-real-money so not load-bearing.
2. **Admin's own agent containers** (`agents-cli-claude-administrator`, `webui-claude-administrator`) still mount docker.sock. Admin's discretion — the demonstrated breach was via websurfinmurf's identity, not admin's.
3. **IBKR portal controls on `U15907310`** still pending: trusted-IP allowlist, sub-account with hard notional/position/daily-loss caps, daily order count cap. Only layer that survives even a fully-owned host. Admin's portal task.
4. **`guacd` joined `mcp-ib-live-net`** for emergency VNC. Anyone reaching guacd (via guacamole-net) can in principle reach the gateway's VNC if they have the password. Accepted because Guacamole sits behind Keycloak ForwardAuth.
5. **`TWS_PASSWORD` readable by host root** via `/proc/<pid>/environ` and `docker inspect`. Unchanged from prior threat-model call. IBKR-side controls are the only mitigation.

## Image supply chain

- `ghcr.io/gnzsnz/ib-gateway:10.41.1e` — pinned. Bump only via deliberate admin review.
- Wrapper image is locally built from `~/projects/mcp/ib/` source. Admin diff-review on every change.
