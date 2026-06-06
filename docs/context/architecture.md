# Architecture

## Purpose
Documentation hub for the Interactive Brokers Gateway stacks (paper + live) running on linuxserver.lan. The active stacks live under `~/projects/mcp/ib-{paper,live}/`; this directory is the umbrella for cross-stack docs, security reviews, and stance documents.

## Tech Stack
- Image: `ghcr.io/gnzsnz/ib-gateway` — `10.41.1e` pinned for live; paper may track a different pin
- IBC (IB Controller, Java) — automates IBKR login + 2FA dialog handling
- socat — IPv4/IPv6 + port forwarding inside the gateway container
- Custom MCP wrapper (Python, `~/projects/mcp/ib/`) — pool of ib_async clients exposing `/health` + `/mcp`

## Components

### Paper stack (`~/projects/mcp/ib-paper/`)
- [IMPLEMENTED] `mcp-ib-paper` — wrapper, exposes `/health` + `/mcp`, talks to gateway via `ibgateway-paper:4004`
- [IMPLEMENTED] `mcp-ib-gateway-paper` — IB Gateway + IBC + socat, paper credentials, paper U-account
- Network: `mcp-ib-paper-net` (with `traefik-net`, `mcp-net` joins for shared-bus consumers like stocktrader-model)

### Live stack (`~/projects/mcp/ib-live/`)
- [IMPLEMENTED] `mcp-ib-live` — wrapper, same image as paper wrapper, pool of 3 workers (client IDs 10/11/12), orders client 198, options client 199
- [IMPLEMENTED] `mcp-ib-gateway-live` — IB Gateway + IBC + socat, live credentials, live account `U15907310`
- Network: `mcp-ib-live-net` **ONLY** — deliberately NOT on `mcp-net` or `traefik-net` (see security.md)

### Legacy (deprecated, do not use)
- [DEPRECATED] `ibgateway-standalone` compose at `./docker-compose.yml` — single-container pre-Bitwarden setup, uses deleted secrets file, would collide on host `:4001` with `mcp-middleware`. Kept on disk for historical reference only.

## Data Flow

```
[stocktrader-model] ──client_id──> mcp-ib-paper:8000 ──ib_async──> ibgateway-paper:4004
                                                                     │
                                                                     └─socat──> 127.0.0.1:4002 (IB Gateway API, paper)

[admin via docker exec] ──> mcp-ib-live:8000 ──ib_async──> ibgateway-live:4003
                                                              │
                                                              └─socat──> 127.0.0.1:4001 (IB Gateway API, live)
```

- Wrapper joins ONE network per stack; gateway joins the same network with alias `ibgateway-{paper,live}`.
- No host ports published on live; paper publishes for shared-bus consumers.

## Integrations

- **IBKR** — upstream broker; live and paper TWS Gateway sessions terminate daily by IBKR policy
- **Bitwarden** — vault for live credentials (`ib-gateway-live`, `ib-gateway-live-vnc` in `administrators` collection of `ai-servicers` org)
- **Promtail → Loki → Grafana** — log shipping, auto-discovered
- **stocktrader-model** — downstream consumer of paper gateway (resting orders, positions, quick-trade)

## Patterns

- **Build-once / promote-by-tag** — image is pinned per stack; admin promotes by tag for live, never by `:latest`
- **Attended start for live** — `start-gateway` (at `~/projects/ib-launcher/`) prompts for Bitwarden master password, fetches secrets, recreates container. No secrets on disk between sessions.
- **Network isolation by trust tier** — paper joins shared buses; live joins nothing else. Hardened 2026-06-03 per Phase A breach fix.
- **IBC auto-2FA selection** — `TWOFA_DEVICE` env var pre-selects the IB Key radio button in the IBKR Second-Factor dialog, so the push fires without VNC interaction.
