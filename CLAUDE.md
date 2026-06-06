---
context-save:
  files: [architecture, operations, security, invariants]
  gotchas_via_memory: false
---

# IB Gateway (Interactive Brokers) — umbrella docs

## Overview
This directory is the documentation umbrella for the IB Gateway stacks. The **active stacks live under `~/projects/mcp/ib-paper/` and `~/projects/mcp/ib-live/`** — those are the projects you edit to change behavior.

Use this dir for: cross-stack security reviews (`docs/reviews/`), stance documents, and the `docs/context/` knowledge files. Do **not** start the legacy `ibgateway-standalone` compose here.

## Quick Reference
| Stack | Project | Container(s) | Image | Status |
|---|---|---|---|---|
| Paper | `~/projects/mcp/ib-paper/` | `mcp-ib-paper` (wrapper), `mcp-ib-gateway-paper` | `ghcr.io/gnzsnz/ib-gateway` | Running |
| Live | `~/projects/mcp/ib-live/` | `mcp-ib-live` (wrapper), `mcp-ib-gateway-live` | `ghcr.io/gnzsnz/ib-gateway:10.41.1e` (pinned) | Running |
| Legacy | `~/projects/ibgateway/` (this dir) | `ibgateway-standalone` | `ghcr.io/gnzsnz/ib-gateway:latest` | **DEPRECATED** — do not start (port collision + deleted secrets) |

## Networks
| Stack | Network | Aliases / wrapper port |
|---|---|---|
| Paper | `mcp-ib-paper-net` + `mcp-net` + `traefik-net` | `ibgateway-paper:4004` (socat → 4002 IB API) |
| Live | `mcp-ib-live-net` ONLY (deliberately no shared bus) | `ibgateway-live:4003` (socat → 4001 IB API) |

## Secrets
| Stack | Source |
|---|---|
| Paper | `~/projects/secrets/ibgateway-paper.env` (admin-managed on disk) |
| Live | Bitwarden vault items `ib-gateway-live` + `ib-gateway-live-vnc` in `administrators` collection of `ai-servicers` org. Fetched at recreate time by `~/projects/ib-launcher/start-gateway.sh`. **Never on disk.** |

## Common Commands

```bash
# Live: recreate (attended, prompts for Bitwarden master password)
CONFIRM_LIVE=yes start-gateway

# Live: bounce without env change
docker restart mcp-ib-gateway-live

# Live: probe wrapper health
docker run --rm --network mcp-ib-live-net curlimages/curl:8.10.1 \
  -sS --max-time 5 http://mcp-ib-live:8000/health

# Paper: recreate
cd ~/projects/mcp/ib-paper && docker compose up -d

# Logs
docker logs mcp-ib-gateway-live --tail 50
```

## Context

Reconstruction-grade knowledge files in `docs/context/`:
- `architecture.md` — components, networks, data flow
- `operations.md` — recreate flows, env vars, 2FA, health probes, Guacamole VNC path
- `security.md` — trust model, credentials, Phase A breach fix, open residuals
- `invariants.md` — load-bearing rules (live isolation, no docker.sock in agent, no rootless on host)

Review artifacts (durable history) in `docs/reviews/`:
- `ib-gateway-running-session-breach.*.md` — 2026-06-03 breach review board
- `rootless-wall-2026-06-03.*.md` — 2026-06-03 rootless wall review board
- `ib-gateway-cred-protection.*.md` — 2026-06-02 credential protection review board

Cross-project perspective:
- `~/projects/portainer/docs/no-rootless.md` — settled position on why rootless docker is not used on this host.

## Logs

Auto-discovered by Promtail → Loki → Grafana.

---
*See `~/projects/CLAUDE.md` for global directives | Last Updated: 2026-06-06*
