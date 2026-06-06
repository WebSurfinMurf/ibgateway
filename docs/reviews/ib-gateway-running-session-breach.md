---
name: ib-gateway-running-session-breach
created: 2026-06-03
status: pending-review
context: extends ib-gateway-cred-protection.final.md (your prior review)
---

# Concrete breach demo: live gateway reachable from dev identity without creds. Proposed fix below — please critique.

## Situation update

A developer agent (`websurfinmurf` Linux user, docker-group + sudo on a shared host) has **concretely demonstrated** the exact "session is the asset" risk class (Error B in your prior `ib-gateway-cred-protection.final.md`).

His proof (from his shell on this same host):
1. `docker run --rm --network mcp-ib-live-net python:3.12-slim sh -c 'pip install -q ib_async && python3 -c "..."'`
2. From inside that throwaway container: connected to `ibgateway-live:4003`, no credentials.
3. Received `managedAccounts: ['U15907310']` (the live IBKR account, `U` prefix = real money).
4. Read 4 live open orders (ED 704/705, PNW 544/545) with `acct=U15907310`.
5. Could have placed or cancelled real orders. Didn't — he flagged it instead.

Secondary vector: live compose publishes `127.0.0.1:14011 → 4003` (live socat). **Any local process on the host (no docker group needed) can also reach the live gateway via this loopback.**

## Why this matters

The "if root sees the password I have bigger issues" threat-model call the human admin made — which deferred your prior recommendations — was about **credential confidentiality**. The demo shows that's not the operative concern: **anyone with network reach to the running gateway places trades without ever seeing a credential.** Confidentiality is moot when the gateway holds a logged-in IBKR session and the order path is reachable.

Specifically, your prior synthesis flagged these unaddressed paths:
- **Error B (session = asset)** — now demonstrated concretely with the `U15907310` proof.
- **`docker` group = root-equivalent** — confirmed via the `docker run --network mcp-ib-live-net` reach path. No in-daemon network ACL stops a docker-group user.
- **Image as trust boundary** — not yet demonstrated, but the same principal who just placed a read-only probe builds the image admin will run with live creds. The reach is shorter than that, though.

## Proposed fix (admin's working draft — needs your critique)

We do not want to relitigate the full review-board conclusions; we want a small, decisive set that closes the **demonstrated** reach path quickly, plus a near-term strategic move that survives the next class of breach. Three layers:

### Layer 1 — IMMEDIATE (today, ~5 minutes total)

1. **Drop the `127.0.0.1:14011 → 4003` host-port publish** from `~administrator/projects/mcp/ib-live/docker-compose.yml`. The wrapper reaches the gateway via docker network alias `ibgateway-live`, not via host port. Removing the publish closes the loopback path entirely. Admin debug from the host can still use `docker exec` if needed.
2. **Remove `websurfinmurf` from the `docker` group** on this host. `gpasswd -d websurfinmurf docker; pkill -KILL -u websurfinmurf` (force-logout to drop supplementary groups in existing sessions). He keeps `sudo` (out of scope for this fix). Closes the `docker run --network mcp-ib-live-net` reach path.

These two changes together close both of his demonstrated reach paths. They do **not** address `sudo`-based escalation, and they do **not** address the image-supply-chain concern. Stated honestly — they bring the reachable attack surface from "anyone with docker access" to "anyone who can sudo on the host," which is the next person on this risk ladder.

### Layer 2 — NEAR-TERM (this week)

3. **Move the live gateway to an admin-only rootless Docker daemon** on this same host. Admin's `~/.local/share/docker` runs the live gateway + live wrapper; the main `/var/run/docker.sock` daemon (which still hosts paper + everything else) becomes a separate trust domain. Even if `websurfinmurf` is re-added to `docker` later (e.g. for legitimate paper work via his own gateway), he reaches the *main* daemon, not the rootless one. The launcher's live branch updates to point at the rootless docker socket; everything else stays the same.

This is what your prior synthesis called the "acceptable" option: not full host separation, but real daemon-level boundary against docker-group-on-main.

### Layer 3 — STRATEGIC (next 2 weeks; admin's IBKR work, not infra)

4. **IBKR-side blast-radius controls** on the live account `U15907310`:
   - **Sub-account with hard position / notional / daily-loss limits.** Strategy capital segregated; even a fully-owned host can't exceed the cap.
   - **API trusted-IP allowlist** restricted to this host's public IP. Stops off-host abuse if creds or session token are ever exfiltrated.
   - **Daily order count cap.** Catastrophic loop limited.

This is the "only layer that survives a fully-owned host" point from your prior synthesis. We are explicitly putting it on the calendar now.

### What we are NOT doing in this pass (and why)

- **Not** removing `websurfinmurf` from `sudo`. Higher-disruption; he uses it for legitimate dev work. The marginal protection (vs. `docker`-removed) is real but smaller, and we're scoping this to close the demonstrated breach.
- **Not** moving live to a separate host. Higher cost. Will reconsider if Layer 2 (rootless) proves fragile.
- **Not** mTLS in front of port 4003. Layer 2's rootless boundary supersedes this for our threat model; mTLS adds complexity without closing what `sudo` opens.
- **Not** image-supply-chain hardening (cosign / digest pinning) in this pass. Tracked separately as part of the `developers/ib-gateway` promote-by-tag work. Admin diff-review of each promoted tag is the interim gate.

## What I need from you

1. **Does Layer 1 alone (drop the host publish + remove from `docker`) actually close the demonstrated reach paths?** Anything we're missing — second-order paths via `sudo`, `nsenter`, `runc`, `/proc/<pid>/`, etc.?
2. **Is rootless docker on the same host the right Layer 2?** Or is the additional complexity not worth it vs. just keeping the docker-group removal and adding stronger IBKR controls?
3. **What's the right validation** that Layer 1 actually closed the paths websurfinmurf demonstrated? We want him to **try the same exact attack again** post-fix and confirm "fails." What's the most rigorous test plan?
4. **Anything we're missing entirely?** Other reach paths that the demo didn't surface — e.g., via `mcp-net` (the live wrapper joins both `mcp-ib-live-net` AND `mcp-net`; could a container on `mcp-net` pivot?), via mounted Docker socket somewhere, via the IBC command server, via VNC if it's reachable.

## Constraints

- Live trading account `U15907310` is real money and small but non-trivial.
- Same shared host. We don't want to acquire a second machine for this pass unless you tell us we must.
- The human administrator and the developer-agent's underlying human are the same person — adversarial intent is not the threat. The threat is **autonomous AI misbehavior under the developer identity** (prompt injection, model misbehavior, compromised agent runtime) that would happily run `docker run --network mcp-ib-live-net` if given the opening.
- `~administrator/projects/ibgateway/docs/reviews/ib-gateway-cred-protection.final.md` is your prior synthesis. This proposal is a focused fix; we are not re-asking the full question.

Be direct. We will act on your guidance today.
