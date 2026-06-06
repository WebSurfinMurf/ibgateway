# Invariants

Load-bearing rules. Breaking any of these = re-open a closed risk. Cite by anchor when justifying changes.

## I-NET-1 — Live stack isolation
The live wrapper (`mcp-ib-live`) and live gateway (`mcp-ib-gateway-live`) join `mcp-ib-live-net` **and no other docker network**.
- Why: any extra join (`mcp-net`, `traefik-net`) re-opens the demonstrated reach path closed in Phase A (2026-06-03).
- Source: `~/projects/ibgateway/docs/reviews/ib-gateway-running-session-breach.final.md`.

## I-NET-2 — No host port publish for live
Neither the live gateway nor the live wrapper publishes any host port.
- Why: any published port is reachable from any local process on the host.
- Admin reaches the wrapper via `docker exec mcp-ib-live`.

## I-AGENT-1 — Autonomous agent containers MUST NOT mount docker.sock
`agents-cli-claude-websurfinmurf`, `webui-claude-websurfinmurf` (and any future autonomous-agent containers) MUST NOT have `/var/run/docker.sock` mounted, MUST NOT have `group_add` with the docker GID.
- Why: docker.sock = host-root-equivalent for the container, which trivially walks into any live netns or wrapper process.
- Phase A breach fix. Re-violating = re-opening the demonstrated breach.

## I-CRED-1 — No live secrets on disk
Live `TWS_USERID` / `TWS_PASSWORD` / `VNC_SERVER_PASSWORD` MUST come from Bitwarden via `start-gateway` at recreate time, MUST NOT live in any `env_file:`, MUST NOT be committed to any repo or compose literal.
- Why: secrets at rest on disk persist past the trust window of the session that fetched them.
- Compose enforces via `${VAR:?…}` fail-loud.

## I-IMAGE-1 — Live image pinned, never `:latest`
The live gateway image MUST be a pinned tag (`ghcr.io/gnzsnz/ib-gateway:10.41.1e` as of 2026-06-03), never `:latest`.
- Why: live trading must not change image bytes silently. Bumps require admin review of release notes + maintain-orders default re-verification.

## I-ROOTLESS-1 — Rootless docker stays off this host
No rootless docker daemon under any uid on `linuxserver.lan`, regardless of how isolated it might appear.
- Why: extensive write-up in `~/projects/portainer/docs/no-rootless.md`. Host root owns rootless sockets and namespaces; the boundary doesn't bind against the actual threat.
- Conditions that would reverse: (a) a second autonomous agent on a different host, (b) live moves to a dedicated machine, (c) untrusted shell users appear on this host.

## I-IDENT-1 — Admin and developer uids are separate
`administrator` and `websurfinmurf` are distinct Linux uids with distinct group memberships. No `NOPASSWD: ALL` sudo line between them. The autonomous AI agent acting "as websurfinmurf" runs in a container as uid 1000, but does not inherit websurfinmurf's docker group.
- Why: Phase A identity split. The human and the autonomous agent are different principals even when sharing a name.

## I-CONTRACT-1 — Stocktrader-model network contract is frozen
Paper: stocktrader-model reaches `ibgateway-paper:4004` on `mcp-ib-paper-net`. This alias + port + network MUST NOT change without coordinated update to stocktrader-model's `IB_GATEWAY_HOST` / `IB_GATEWAY_PORT`.
- Live: `ibgateway-live:4003` on `mcp-ib-live-net` (admin-only consumer).
- Why: stocktrader is a downstream production app; silent contract change = silent breakage.

## I-2FA-1 — Live restart window is during waking hours
`AUTO_RESTART_TIME` for live MUST be a time when admin is awake and can tap the 2FA push. Currently `07:00 AM` America/New_York.
- Why: 2FA push is mandatory daily (IBKR policy, not bypassable). If missed at 3 AM, IBC retries continuously and IBKR enforces a 4 min 55 sec cooldown per failed attempt — observed 58 retries overnight before tap (2026-06-06).
- TZ is set explicitly so DST is tzdata-handled, not a hardcoded UTC offset that drifts twice a year.
