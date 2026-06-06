---
name: ib-gateway-running-session-breach
created: 2026-06-03
status: review-complete
sources: [gemini, codex, claude]
extends: ib-gateway-cred-protection.final.md
---

# Final fix — running-session breach (synthesis)

## Headline

**Layer 1 as proposed is incomplete and would have given a false sense of "done."** All three reviewers — independently — converged on the same set of additional changes that must land in the same pass to actually close the demonstrated risk class. The good news: every additional change is small and lands today.

The proof from the host:
- **`mcp-net` pivot confirmed open** — `mcp/ib-live/docker-compose.yml` lines 32-33 attach the live wrapper to `mcp-net` and `traefik-net`. Any container on `mcp-net` (code-executor, proxy, others) can hit the live wrapper directly and trigger orders. This path is *shorter* than the docker-attach websurfinmurf demoed; Layer 1 as written would not touch it.
- **`sudo` requires password** on this host — `sudo -n true` from `administrator` failed. Assuming same policy for `websurfinmurf` (verify with `cat /etc/sudoers /etc/sudoers.d/*`), the autonomous agent cannot scriptably `sudo`. **That makes rootless Layer 2 a real boundary, not theater.** Critical answer that the board flagged as the deciding question.

## Consensus across all three reviewers

1. **Drop `14011` and remove from `docker` group closes the two commands he ran.** All three agree.
2. **Three additional host publishes must be dropped in the same pass:** `15901` (VNC, GUI order surface), `14012` if present, and `48014` (wrapper HTTP). Codex named these by line number; Claude flagged VNC specifically as a "standing order backdoor"; Gemini called the VNC bypass.
3. **The live wrapper must come off `mcp-net` and `traefik-net`.** Claude called this the #1 missing path; Codex listed it as immediate item #3; Gemini called it the "critical" lateral bypass.
4. **`/var/run/docker.sock`-mounting containers survive docker-group removal.** Codex named `mcp/code-executor` and `mcp/ib-paper`; Claude flagged the same pattern as a "docker-group equivalent." Either the agent must not be able to exec into them, or they must lose the socket mount.
5. **Rootless Docker is the right Layer 2** — but only if both gateway AND wrapper move into it together. A rootless gateway behind a rootful wrapper on `mcp-net` is the same breach with extra steps.
6. **IBKR-side controls (sub-account, trusted-IP, daily caps) must move forward from "strategic" to "this week."** All three reviewers: this is the only layer that survives a fully-owned host, and it's IBKR-side config, not infra work — it doesn't compete for the same hours.
7. **The "identity split" recommendation from the prior synthesis silently disappeared from this proposal.** Claude (the same reviewer as the prior synthesis) flagged that the proposal substitutes "remove from docker" for "give the agent its own non-sudo/non-docker uid" — a real downgrade. Even with passwordful sudo, splitting the agent's runtime identity from the human's is cheap insurance.
8. **Validation must run from the agent's actual identity** (not admin's), with a matrix of 8+ tests including application-layer silence on `U15907310` from agent-reachable surfaces. Not just "did the one command he typed stop working."

## Disagreements (minor)

- **Codex** lists `48014:8000` as the wrapper's host publish to drop. **Claude** doesn't name this port explicitly. **My read:** Codex is right — it's a published port reachable from any local process and from anything on `mcp-net`; remove it.
- **Codex** says "remove live wrapper from both `mcp-net` and `traefik-net`." **Claude** says "off `mcp-net`; expose to the algo through one deliberately narrow channel." **My read:** for *this* deployment, no algo currently consumes the live wrapper from outside (stocktrader-live isn't built yet), so remove both networks now and add a narrow channel later if/when needed.
- **Gemini** emphasizes that rootless is "defeated by sudo." All three reviewers agree, with different weights. **My read:** sudo-requires-password on this host (verified) means rootless does buy a real boundary. The sudo gap is a residual to be backstopped by Layer 3, not a reason to skip Layer 2.

## Final fix

### Phase A — DO TODAY (blocking; recreate live after)

A1. **Edit `~administrator/projects/mcp/ib-live/docker-compose.yml`:**
   - **Drop the wrapper's `mcp-net` and `traefik-net` joins** (lines 32-33). Wrapper now joins ONLY `mcp-ib-live-net`. (Consequence: anything currently on `mcp-net` that calls `mcp-ib-live:8000` breaks. Intended.)
   - **Drop the wrapper's host port publish** (line ~27: `48014:8000`). Wrapper is internal-only; admin reaches it via `docker exec` or via a SSH tunnel if needed.
   - **Drop all gateway host port publishes:** `127.0.0.1:14011:4003` (gateway socat) and `127.0.0.1:15901:5900` (VNC) — both. Admin debug → `docker exec`. VNC → `docker exec` plus host-side x11vnc / one-time SSH tunnel if/when needed for settings.

A2. **Recreate live:** `CONFIRM_LIVE=yes start-gateway` (drops + recreates the containers with new compose).

A3. **Remove `websurfinmurf` from `docker` and force-logout:**
   ```
   sudo gpasswd -d websurfinmurf docker
   sudo pkill -KILL -u websurfinmurf
   ```

A4. **Confirm no respawners** for the websurfinmurf user that could re-establish a docker-socket-holding container:
   ```
   sudo crontab -u websurfinmurf -l 2>/dev/null
   sudo systemctl --user --machine websurfinmurf@ list-units 2>/dev/null
   sudo -u websurfinmurf atq 2>/dev/null
   ```
   Nuke any that look like they re-establish docker access.

A5. **`chmod 700` the live state dirs:**
   ```
   sudo chmod 700 ~administrator/projects/mcp/ib-live/jts ~administrator/projects/mcp/ib-live/ibc 2>/dev/null
   ```
   (Only if they exist as bind-mount targets; the current refactored compose may not use them — confirm before chmod-ing nothing.)

A6. **Verify sudoers** policy for websurfinmurf:
   ```
   sudo grep -RE 'websurfinmurf|NOPASSWD' /etc/sudoers /etc/sudoers.d/ 2>/dev/null
   ```
   If any `NOPASSWD` rule applies to him: this is the most critical residual the board flagged. Remove the `NOPASSWD` (require password going forward), OR commit to Phase B's identity split now instead of this week.

### Phase B — VALIDATE (today, after Phase A)

Run from `websurfinmurf`'s identity, AFTER force-logout + fresh login. Every test must fail (refused / 404 / denied). Pass criterion: **application-layer silence on `U15907310` from every agent-reachable surface**, not just refused TCP.

B1. **Docker socket denied:** `docker ps` → permission denied.
B2. **Exact replay:** the original `docker run --network mcp-ib-live-net ...` probe → fails before container start.
B3. **Loopback raw gateway:** `nc -zv 127.0.0.1 14011` → refused.
B4. **Loopback VNC:** `nc -zv 127.0.0.1 15901` → refused.
B5. **Loopback wrapper:** `curl -sf http://127.0.0.1:48014/health` → refused.
B6. **mcp-net pivot (the critical one):** from `mcp-code-executor` (which is on `mcp-net`): `curl -sf http://mcp-ib-live:8000/health` → DNS fails or refused. Also: `curl -sf http://mcp-ib-live:8000/orders` → same.
B7. **Proxy route:** if the proxy (`mcp-proxy` on `:9090`) has a route registered for ib-live, `curl -sf http://localhost:9090/ib-live/mcp` → 404 or refused.
B8. **Docker-socket pivot:** enumerate via `docker ps --format '{{.Names}} {{.Mounts}}' | grep docker.sock`. For each that the agent can exec into, attempt `docker -H unix:///var/run/docker.sock run --network mcp-ib-live-net ...` → must fail (ideally because exec is denied).
B9. **Sudo reality check (DOCUMENT the residual):** `sudo nsenter -t <gw_pid> -n -- nc -zv 127.0.0.1 4001` → expected to succeed; this is the residual `sudo` path that Phase C addresses. Record it.
B10. **Negative control:** as admin, confirm legitimate live path still works. Connect from `mcp-ib-live` wrapper to `ibgateway-live:4003` → `accounts: ['U15907310']`.

### Phase C — THIS WEEK (parallel tracks; pulled forward from "strategic")

C1. **IBKR-side blast-radius controls on `U15907310`** (admin's IBKR portal task, not infra):
   - **API trusted-IP allowlist** restricted to this host's public egress IP.
   - **Sub-account with hard position / notional / daily-loss limits** for strategy capital.
   - **Daily order count cap** to bound catastrophic loops.
   These survive a fully-owned host. They are not optional anymore.

C2. **Identity split for the autonomous agent** (independent of sudo policy — both reviewers' prior recommendation that silently dropped from this proposal):
   - The autonomous AI runtime gets its own Linux uid (e.g., `websurfinmurf-agent`), **not in `sudo`, not in `docker`**.
   - The human `websurfinmurf` keeps their normal identity (with whatever access they need for hands-on dev work).
   - The launcher's paper-branch dispatch case widens to match `*-agent` too.

C3. **Rootless docker daemon for the entire live stack** (gateway + wrapper together):
   - Admin's user runs a rootless docker daemon at `~administrator/.local/share/docker`.
   - Live gateway + live wrapper move there. Private bridge network.
   - Launcher's live branch points at the rootless docker socket.
   - Verifies the daemon-level boundary against any future docker-group regression.

### Phase D — DEFERRED (acceptable per the prior threat-model call)

- Separate physical host. Rootless on this host is the accepted substitute.
- mTLS in front of port 4003. Rootless boundary supersedes this for our threat model.
- cosign / digest-pinning the live image. Admin diff-review on each promoted tag is the interim gate (verify this gate is enforced as a hard stop, not a courtesy).

## Risks flagged (residual after the fix)

- **`sudo` survives Phase A and B.** Anyone with sudo on this host can ptrace the JVM, `nsenter` into the gateway netns, read `/proc/<pid>/environ`, mount admin's rootless socket. The IBKR sub-account cap (C1) is the only layer that survives this; that's why it moves to "this week."
- **Image source still admin's working tree, not pinned to a published digest.** Promote-by-tag is in flight (`developers/ib-gateway`); until then, the live `docker compose build ../ib` path is uncontrolled. Diff-review on each promotion is the only gate.
- **Vault items remain visible to root.** Live `TWS_PASSWORD` etc. are in the container env at runtime; visible to `docker inspect` (from rootless socket) and `/proc/<pid>/environ` (via sudo). Same residual as the prior synthesis. Not addressable without per-process secrets and IBKR app cooperation we don't have.
- **Paper-side work continues on the rootful daemon.** That's fine — paper is dev's playground; the boundary is at the live daemon, not at all docker.

## What the admin tells the user back

Three quick decisions are needed before B can fully validate:

1. **Are there any non-admin consumers currently calling `mcp-ib-live:8000` over `mcp-net`?** If yes, name them — they'll break in A1. (Likely answer: no, since live wrapper just stood up yesterday and stocktrader-live isn't built yet.)
2. **Sudoers check for `websurfinmurf` — is there any `NOPASSWD`?** Determines whether Phase C2 (identity split) is "this week" or "today."
3. **Comfort with VNC being unreachable without `docker exec`?** Admin's one-time settings access becomes a `docker exec` + container-internal VNC tunnel, rather than `localhost:15901`. Workable but a small habit change.
