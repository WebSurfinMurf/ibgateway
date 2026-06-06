---
source: claude
reviewed: 2026-06-03
context: ib-gateway-running-session-breach.md
---

I have enough to answer rigorously. Two of the most security-relevant files (`mcp/ib-live/docker-compose.yml` and `mcp/ib-paper/docker-compose.yml`) are mode 0640 owned by `administrator` and I'm sandboxed as `swarm`, so I could not read them directly. I reconstructed the topology from the readable `mcp/ib/CLAUDE.md` (the paper reference), `mcp/CLAUDE.md`, the code-executor reference pattern, and the live `deploy.sh`. Where a conclusion depends on a file I couldn't read, I say so and give you the one command to confirm.

---

# Review: running-session breach fix

**Headline:** Layer 1 closes the two commands he typed. It does **not** close the demonstrated *risk class*, because there is a **shorter order path than the one he demoed that Layer 1 never touches** — and the single most decisive recommendation from the prior synthesis (split the agent's identity from the human's) has silently dropped out of this plan. Fix those two things before you call this done today.

Let me take the four questions in order, then the blind spots, then a corrected action list.

---

## Q1 — Does Layer 1 close the demonstrated reach paths?

**Partially. It closes both *specific* commands, but leaves three sibling paths open, two of which are loopback paths you explicitly intended to close.**

**What Layer 1 does close:**
- `docker run --network mcp-ib-live-net …` → gone once `websurfinmurf` loses the `docker` group **and** you `pkill -KILL -u` him (correct — group membership doesn't revoke in live sessions; you've got the kill).
- `127.0.0.1:14011 → 4003` loopback → gone once you drop that publish.

**What Layer 1 as written leaves open:**

1. **VNC is still published on loopback.** Your live `deploy.sh` advertises `15901 (VNC)`. VNC into a logged-in live gateway is a full GUI order-placement surface — click-to-trade, no API, no creds. Layer 1's drop-list only names `14011`. **You must drop the VNC publish too** (and `14012` if the live stack also publishes a paper socat — the deploy.sh echoes it). Dropping one of three published order surfaces and declaring the loopback vector closed is the kind of gap that reads as "done" but isn't.

2. **The docker-socket-mounting container = a `docker`-group equivalent that survives group removal.** The prior synthesis flagged that the paper wrapper mounts `/var/run/docker.sock`. Any container the agent can run code in that has the socket mounted *is* the docker daemon. Removing `websurfinmurf` from the `docker` group does nothing about a container that already holds a socket handle. If the agent can reach the paper wrapper (or code-executor, or anything socket-mounted) and run a shell there → `docker -H unix:///var/run/docker.sock run --network mcp-ib-live-net …` → same breach. **Enumerate every container mounting the socket and confirm the agent can't execute inside it.**

3. **Second-order via `sudo`** (you've scoped this out, correctly labeled): `sudo cat /proc/<gw_pid>/environ`, `sudo nsenter -t <gw_pid> -n` into the gateway's netns then connect to 127.0.0.1:4001 directly, `sudo ptrace`/`gcore` the JVM. These all survive Layer 1 **and** Layer 2. More on why this matters in Q2.

**Process-hygiene nit on the force-logout:** `pkill -KILL -u websurfinmurf` kills live processes but not things that *respawn* — user `cron`, `at`, or `systemd --user` units. Before declaring the docker path closed, confirm none exist (`crontab -u websurfinmurf -l`, `systemctl --user --machine websurfinmurf@ list-units`, `atq`). One lingering `@reboot` unit that re-establishes a docker-socket container undoes this.

---

## Q2 — Is rootless docker the right Layer 2?

**Rootless is the right *mechanism* for a cheap, real same-host daemon boundary — but it only delivers the protection you want under two conditions the proposal doesn't state, and against your actual threat model it may be close to theater. Walk through this carefully before committing the week to it.**

**Where rootless genuinely helps:** a container on the *main* daemon's `mcp-net` cannot reach a container in admin's *rootless* daemon — separate network namespace, separate bridge. So if `websurfinmurf` is ever re-added to the main `docker` group for legit paper work, `docker run --network mcp-ib-live-net` finds no such network on the main daemon. That's a real boundary, and rootless is cheaper than a VM. Good instinct.

**Condition 1 — the wrapper must move into rootless too, not just the gateway.** This is the subtle trap. The live *wrapper* is the thing that holds the order-placement tools, and (per the paper reference) it sits on `mcp-net` precisely so the proxy/agent can call it. If you move the *gateway* into rootless but leave the *wrapper* on the main daemon's `mcp-net`, you haven't moved the boundary — you've just relocated it behind a still-reachable proxy. The agent calls the wrapper over `mcp-net`/`9090`; the wrapper calls the gateway over rootless… and you're owned again, without docker or sudo. **Both gateway and wrapper move into rootless, and the live wrapper must NOT rejoin the shared `mcp-net`.** (See Q4 — this is the path the whole plan is missing.)

**Condition 2 — the agent identity must not have scriptable `sudo`.** This is the pivot the proposal walks past. A `sudo` user reads admin's rootless socket at `$XDG_RUNTIME_DIR/docker.sock`, `nsenter`s into the rootless containers, ptraces the JVM, reads `/proc/<pid>/environ`. **Rootless does not survive `sudo` any more than the main daemon does.** Your stated threat is *autonomous AI misbehavior under the developer identity*. If that identity has passwordless/scriptable `sudo`, then Layer 1 + rootless Layer 2 are both bypassable by the exact actor you're defending against — a prompt-injected agent will `sudo nsenter` as happily as it ran `docker run`. The proposal frames sudo as "the next person up the ladder." It isn't the next person — **it's the same agent**, and for an AI agent the only question is whether `sudo` prompts for a password it doesn't have.

So the decisive, unstated question: **is the autonomous agent's `sudo` passwordless or AI-scriptable?**
- If **sudo prompts** for a password the agent can't supply → `docker` was the only scriptable root path, and rootless genuinely closes the breach class. Commit to it.
- If **sudo is passwordless/NOPASSWD** for that identity → Layer 1 + rootless are theater against the stated threat; the agent sudos around both. Then the real fix is not rootless, it's **the identity split the prior synthesis led with: give the autonomous agent its own Linux uid that is neither in `docker` nor `sudo`.** That recommendation has disappeared from this plan and it shouldn't have.

**My recommendation on Q2:** Rootless is worth doing *and* it's not sufficient alone. Do rootless for the gateway **and the wrapper together**, AND give the autonomous agent runtime its own non-`sudo`, non-`docker` uid (distinct from the human's interactive `websurfinmurf`, who can keep sudo for hands-on work). The combination is coherent and cheap. Rootless with a sudo-capable agent is not — in that configuration the additional complexity over "just docker-removed + strong IBKR controls" buys you very little, and you'd be better off spending the week on Layer 3.

---

## Q3 — Validation test plan

"Have him re-run the exact attack and confirm it fails" is **necessary but badly insufficient** — it tests one of five paths and gives false confidence on the other four. Run a matrix, from the **agent's actual identity** (not admin's), with negative controls. Every test below should **fail/refuse** post-fix; the two marked ⚠️ are the ones the proposal's plan wouldn't catch.

**Setup (capture baseline first):**
- `ss -ltnp` and `docker ps --format '{{.Names}} {{.Ports}}'` (admin) → snapshot every published port touching live.
- Fresh login as the agent identity, `id` → confirm no `docker` group.

**Attack matrix (run as the agent identity):**
1. **Exact replay** — the `docker run --network mcp-ib-live-net … ib_async` probe → expect `permission denied … /var/run/docker.sock`. Also bare `docker ps` → denied.
2. **Live socat loopback** — `nc -zv 127.0.0.1 14011` and an `ib_async` connect → connection refused.
3. ⚠️ **VNC loopback** — `nc -zv 127.0.0.1 15901` → refused. (Flag loudly if still open — it's a GUI order path.)
4. **Port sweep** — `ss -ltnp | grep -E '1401|1402|1590'` from his shell → nothing reaching live.
5. ⚠️ **`mcp-net` / proxy order path (the important one)** — from a surface the agent actually drives on `mcp-net` (code-executor), and from host loopback against the proxy:
   - `curl -s http://mcp-ib-live:<port>/mcp -d '{…tools/list…}'`
   - `curl -s http://localhost:9090/<live-route>/mcp -d '{…tools/list…}'`
   → expect no route to the live wrapper / no order tools / no `U15907310`. **At the application layer**, not just TCP: confirm `managedAccounts` and open-orders return nothing for the live account from any agent-reachable surface.
6. **Socket-mounted container pivot** — admin enumerates containers with `/var/run/docker.sock` mounted; for each the agent can exec into, attempt `docker -H unix:///var/run/docker.sock run --network mcp-ib-live-net …` → must fail (ideally because the agent can't exec there at all).
7. **Known-residual (document, don't fix today)** — `sudo cat /proc/<gw_pid>/environ` and `sudo nsenter -t <gw_pid> -n -- nc -z 127.0.0.1 4001` → these will **succeed**; record them as the residual that justifies Layer 3 + the identity split.
8. **Negative control** — admin's legitimate wrapper still reaches the gateway; paper trading unaffected. (A fix that also breaks the real path isn't validated, it's just broken.)

**Two procedural rules:** run the matrix *after* the `pkill -KILL -u` + fresh login (so no lingering session retains the group), and make the pass criterion *application-layer silence on `U15907310`*, not merely a refused TCP connect.

---

## Q4 — What are we missing entirely?

**The biggest miss is the one you half-suspected in your own question 4: the `mcp-net` → live-wrapper order path.** Spelling it out, because it changes the plan:

The live wrapper, like the paper wrapper (`mcp/ib/CLAUDE.md` confirms the pattern: wrapper on `mcp-ib-net` **+** `mcp-net`), exists to place orders and is attached to the shared `mcp-net` so the TBXark proxy (`:9090`) and other MCP containers can call it. **`mcp-net` is a shared bus** — code-executor (which the AI agent drives directly), the proxy, minio, openmemory, tradingview, vikunja all sit on it. So:

> AI agent → code-executor (already on `mcp-net`) → `curl http://<live-wrapper>:<port>/mcp` (or `localhost:9090/<live-route>/mcp`) → order tools → real orders on `U15907310`.

**No `docker` group. No `sudo`. No loopback port.** This path is *shorter* than the one `websurfinmurf` demoed, and **Layer 1 does not touch it.** He demoed the docker path because that's what he reached for; the wrapper path was sitting right next to it. If the live wrapper has order tools enabled and is on `mcp-net`, removing him from `docker` and dropping `14011` leaves the account just as reachable.

> **Confirm in 30 seconds** (you can read the file; I couldn't): does `mcp/ib-live/docker-compose.yml` list `mcp-net` under the wrapper's `networks:`, and is the live route registered in `mcp/proxy/config.json`? If yes to either, this path is live and is your top priority — above the loopback drop. The fix is Condition 1 from Q2: move the wrapper into rootless and keep it **off** `mcp-net`; expose it to the algo through one deliberately narrow channel, not the shared bus.

Other reach paths the demo didn't surface:
- **VNC `15901`** (covered in Q1) — standing GUI order backdoor; bind `127.0.0.1` only and disable when admin isn't actively using it, SSH-tunnel for the rare settings pass.
- **Docker-socket-mounting containers** (Q1 #2) — `docker`-equivalents that survive group removal.
- **IBC command server.** The gnzsnz image runs IBC, which has a telnet-style command server (commonly `7462`) accepting `ENABLEAPI`/`RESTART`/`STOP`. Verify it's not published and not on `mcp-net`. It's another control surface that bypasses the API entirely.
- **`./jts` and `./ibc` host dirs** hold remembered settings and trusted-device/session state. If group/world-readable, a non-docker local process copies them. `chmod 700`, owned by the rootless-daemon user.
- **Image build at deploy time.** Your live `deploy.sh` runs `docker compose build` — live is **not** pull-only/pinned (contradicts Phase 2 of the prior review). You've deferred supply-chain explicitly and that's a defensible scoping call, but note the interaction: removing the agent from `docker` does **not** stop it from poisoning the `developers/ib-gateway` *source tree* that admin later builds and runs with live creds. Your "admin diff-reviews each promoted tag" gate is the *only* control there — make sure it's actually enforced as a gate, not a courtesy, because Layer 1/2 give zero protection against it.

---

## Blind spots a same-context reviewer would miss

1. **The plan optimizes against the demo, not the threat model.** The demo used `docker`; the plan removes `docker`. But your own constraints say the threat is *an autonomous agent under the developer identity*. That agent's worst-case capability is bounded by whether it can `sudo`, not by whether it's in `docker`. A reviewer anchored on "validate these three layers" will check that the three layers do what they say and miss that **the layers are scoped to the wrong variable.** If the agent can sudo, you've hardened the easy path and left the agent's actual ceiling untouched until Layer 3 — which you've parked two weeks out.

2. **The prior synthesis's lead recommendation quietly vanished.** `ib-gateway-cred-protection.final.md`, Phase 1, item 4: *"Split the human and the AI agent identities. Give the AI its own Linux user. Not in sudo, not in docker."* That was the synthesized "simplest defensible plan that survives all three reviews," step 1. This proposal keeps the agent **as** `websurfinmurf` and substitutes "remove from docker." A same-context reviewer reading only this doc won't notice the substitution. It matters because the identity split is the thing that makes everything downstream (rootless, `env_file` 600) actually mean something — it's what guarantees the only principals who can reach the live daemon are ones you trust. Put it back.

3. **Layer 3 is mis-tiered.** You've labeled IBKR-side controls "strategic / next 2 weeks." But Layers 1–2 don't survive `sudo`, and (pending your answer on passwordless-sudo) the agent may have sudo. **The IBKR trusted-IP allowlist + sub-account hard cap is the only control that holds when the agent sudos or when the host is fully owned** — the prior synthesis called the sub-account "the single most defensible recommendation in the entire review." That's not strategic-tier insurance; for your threat model it's the *primary* control. Pull at least the trusted-IP allowlist and the sub-account notional cap forward to **this week**, parallel with Layer 2. They're IBKR-side config, not infra work — they don't compete for the same hours.

---

## Corrected action list for today

**Do now (closes the demonstrated paths *and* their siblings):**
1. Drop the live host publishes — `14011` **and `15901` (VNC)** and any `14012` on the live stack. Not just the one port.
2. `gpasswd -d websurfinmurf docker` → `pkill -KILL -u websurfinmurf`, then confirm no respawners (`crontab -l`, `systemctl --user list-units`, `atq`).
3. **Confirm the `mcp-net` pivot** (read your own `ib-live/docker-compose.yml` + `proxy/config.json`). If the live wrapper is on `mcp-net` or registered in the proxy, that's your #1 — close it (take the live wrapper off the shared bus) before you consider the loopback handled.
4. Enumerate socket-mounting containers; confirm the agent can't exec into any.
5. `chmod 700` the live `./jts` and `./ibc`.

**Answer one question that decides everything:** *Is the autonomous agent's `sudo` passwordless / scriptable?* If yes → the identity split (own non-sudo/non-docker uid for the agent) is not optional and rootless-alone is theater. If no → rootless is genuinely sufficient at the daemon layer.

**This week (not "strategic"):**
6. Rootless Layer 2 — **gateway + wrapper together**, wrapper off `mcp-net`.
7. IBKR trusted-IP allowlist (this host's public IP) + sub-account hard notional/position cap. This is the layer that survives the residual `sudo`/full-ownership path; it's cheap IBKR config, do it in parallel.

The one-line version: **your two changes close his two commands, but the account is still reachable through the live wrapper on the shared MCP bus, through VNC, and through any socket-mounted container — and the whole stack is bypassable by `sudo` unless you either confirm sudo prompts or give the agent its own unprivileged uid.** Confirm the `mcp-net` wiring before you tell yourself the loopback is the last door.

Want me to draft the corrected Layer-1 diff (compose port edits + the `mcp-net` removal) once you've confirmed whether the live wrapper is on that network? I can only read it if you relax the 0640 perms or paste the `networks:` block.
