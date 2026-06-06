---
source: codex
reviewed: 2026-06-03
context: ib-gateway-running-session-breach.md
---

Short answer: Layer 1, as written, closes the two exact proofs, but it does not close the broader "live session reachable from dev identity" problem. If you act today, do Layer 1 plus three more changes immediately: remove the live wrapper host publish, remove the live wrapper from shared networks, and remove the live VNC publish except during an admin-only maintenance window.

**1. Layer 1**
For the two demonstrated paths, yes:
- Removing `127.0.0.1:14011:4003` from [docker-compose.yml](/workspace/administrator/projects/mcp/ib-live/docker-compose.yml:65) closes the host-loopback raw gateway path.
- Removing `websurfinmurf` from `docker` and killing all his sessions closes the exact `docker run --network mcp-ib-live-net ...` path.

But Layer 1 does not close live reach overall:
- The live wrapper is still published on `48014:8000` at [docker-compose.yml](/workspace/administrator/projects/mcp/ib-live/docker-compose.yml:27).
- The live wrapper is still attached to shared `mcp-net` and `traefik-net` at [docker-compose.yml](/workspace/administrator/projects/mcp/ib-live/docker-compose.yml:30).
- The wrapper exposes unauthenticated HTTP control/data endpoints: `/gateway/status`, `/gateway/login`, `/gateway/logout`, `/gateway/reconnect` at [server.py](/workspace/administrator/projects/mcp/ib/src/server.py:1731), and `/orders`, `/orders/single`, `/orders/combo`, `/orders/{id}` at [server.py](/workspace/administrator/projects/mcp/ib/src/server.py:2128).
- If `IB_READONLY=false` is ever enabled for live, that wrapper becomes another no-credential order path. The toggle is in [docker-compose.yml](/workspace/administrator/projects/mcp/ib-live/docker-compose.yml:23).

So my answer is: Layer 1 closes the demonstrated raw-gateway paths, but not the actual live trading surface. If you want to say "breach closed," Layer 1 needs these additions today:
- Remove `48014:8000` entirely, not just leave it published.
- Remove `mcp-net` and `traefik-net` from the live wrapper.
- Remove `127.0.0.1:15901:5900` except for temporary admin use.

Also: `sudo` still breaks everything. Once `sudo` remains, `nsenter` / `runc` / `/proc` are not separate problems worth analyzing one by one.

**2. Rootless Docker**
Yes, rootless Docker is the right Layer 2 on one host, but only if you move the entire live stack there, not just the gateway container.
- Move both `mcp-ib-live` and `mcp-ib-gateway-live` off the shared rootful daemon.
- Give the live stack its own admin-only rootless daemon and private bridge network.
- Do not attach live services to rootful `mcp-net` or `traefik-net`.
- Update the launcher, which currently runs plain `docker compose up -d` against the shared daemon at [start-gateway.sh](/workspace/administrator/projects/ib-launcher/start-gateway.sh:147).

Why this is worth doing:
- It cleanly kills the "shared rootful daemon" trust problem.
- It survives accidental re-addition of the developer to the main `docker` group.
- It is much cheaper than a second host.

What it does not do:
- It does not defend against a user who can freely `sudo` on the host.
- It does not replace IBKR-side limits. Those are still mandatory backstops.

So the right framing is: rootless is the right near-term isolation layer; IBKR controls are the damage cap, not the substitute.

**3. Validation**
Use a fail-closed test plan, with the developer re-running the same attacks after a forced re-login.

Required negative tests as `websurfinmurf` after `pkill -KILL -u websurfinmurf`:
1. `id -nG` no longer contains `docker`.
2. `docker ps` fails with socket permission denied.
3. Re-run the exact proof command `docker run --rm --network mcp-ib-live-net ...`; it must fail before container start.
4. `nc -vz 127.0.0.1 14011` must fail.
5. `nc -vz 127.0.0.1 15901` should also fail if you actually closed VNC.
6. `curl http://127.0.0.1:48014/health` and `curl http://127.0.0.1:48014/orders` should fail. If they succeed, live is still reachable locally.
7. From any container on rootful `mcp-net`, `curl http://mcp-ib-live:8000/health` should fail and the name ideally should not resolve.
8. `docker network inspect mcp-net` on the rootful daemon should show no live containers after the rootless move.

Required pivot tests:
- From `mcp-code-executor`, verify it cannot enumerate or control live containers. Right now it mounts `/var/run/docker.sock` and adds docker group GID at [docker-compose.yml](/workspace/administrator/projects/mcp/code-executor/docker-compose.yml:41).
- From `mcp-ib-paper`, verify it also cannot reach live. Right now it mounts the Docker socket too at [docker-compose.yml](/workspace/administrator/projects/mcp/ib-paper/docker-compose.yml:21).

Important: a Docker socket bind-mounted `:ro` is still full Docker API access in practice. Do not treat that as read-only protection.

Then run one positive admin smoke test:
- As `administrator`, confirm the intended live path still works and only through the intended admin-only control path.

**4. Missing Reach Paths**
The big ones you are currently missing are:
- The live wrapper host port `48014:8000` on [docker-compose.yml](/workspace/administrator/projects/mcp/ib-live/docker-compose.yml:27).
- The live wrapper on shared `mcp-net` and `traefik-net` at [docker-compose.yml](/workspace/administrator/projects/mcp/ib-live/docker-compose.yml:30).
- Unauthenticated wrapper endpoints for order read/control and gateway control at [server.py](/workspace/administrator/projects/mcp/ib/src/server.py:1731) and [server.py](/workspace/administrator/projects/mcp/ib/src/server.py:2128).
- Shared Docker-socket pivots: [mcp/code-executor/docker-compose.yml](/workspace/administrator/projects/mcp/code-executor/docker-compose.yml:41) and [mcp/ib-paper/docker-compose.yml](/workspace/administrator/projects/mcp/ib-paper/docker-compose.yml:21).
- Live VNC on `127.0.0.1:15901` at [docker-compose.yml](/workspace/administrator/projects/mcp/ib-live/docker-compose.yml:66). Any local process can still drive that session.
- Supply-chain reach: the live wrapper is still locally built from `../ib` at [docker-compose.yml](/workspace/administrator/projects/mcp/ib-live/docker-compose.yml:12). That is not a network path, but it is still a direct route to live-session compromise.

If you want the direct "do this today" list:
1. Apply Layer 1.
2. Remove `48014` publish from live.
3. Remove live from `mcp-net` and `traefik-net`.
4. Remove `15901` publish except during supervised admin maintenance.
5. Keep `IB_READONLY=true` until the rootless move is complete.
6. Move the full live stack to an admin-only rootless daemon this week.
7. Treat all shared Docker-socket mounts as equivalent to rootful-daemon access and out of trust for live.

If any other automation on this host truly needs live access by design, say that explicitly, because then this stops being a simple network-isolation fix and becomes an authentication/authorization redesign.
