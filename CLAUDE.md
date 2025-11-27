# IB Gateway (Interactive Brokers)

## Overview
Interactive Brokers Gateway for algorithmic trading API access. Supports paper and live trading modes.

## Quick Reference
| Property | Value |
|----------|-------|
| Container | ibgateway-standalone |
| Ports | 4001 (live), 4002 (paper), 5900 (VNC) |
| URL | N/A (API only, not web accessible) |
| Image | ghcr.io/gnzsnz/ib-gateway:latest |
| Status | Running |

## Networks
- ibgateway-net (isolated)

## Dependencies
- None (standalone service)
- MCP-IB server connects to this gateway

## Data
- JTS config: `./jts`
- IBC config: `./ibc`

## Secrets
Location: `$HOME/secrets/ibgateway.env`
- IB_USERNAME
- IB_PASSWORD
- TRADING_MODE (paper/live)
- VNC_SERVER_PASSWORD

## Integration
- **MCP-IB**: `/home/administrator/projects/mcp/` connects to ports 4001/4002
- **Trading Mode**: Set via TRADING_MODE environment variable

## Logs
Auto-discovered by Promtail → Loki → Grafana

## Common Commands
```bash
# Deploy
cd /home/administrator/projects/ibgateway && docker compose up -d

# Logs
docker logs ibgateway-standalone --tail 50

# VNC access (if enabled)
# Connect to linuxserver.lan:5900

# Restart
docker compose restart ibgateway
```

---
*See directives.md for standards | Last Updated: 2025-11-27*
