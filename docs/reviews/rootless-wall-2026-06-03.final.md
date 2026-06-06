---
name: rootless-wall-2026-06-03
created: 2026-06-03
status: review-complete
sources: [gemini, codex, claude]
---

# Final synthesis — Rootless wall + path forward

## Headline

**All three reviewers say: stop fighting rootless on this host.** They diverge on *what to do instead*. Gemini + Codex say "local VM (B)." Claude says **B is also a non-boundary because host root owns local VMs** — the load-bearing fix is removing the agent's path to host root via the docker socket, then bounding blast radius with IBKR-side controls. Claude's diagnosis is more rigorous, identifies a specific cost I introduced (a host-wide AppArmor weakening that hurts security for all 60+ containers), and reframes the entire problem statement: I was debugging a boundary that doesn't bind against the stated threat.

## Consensus (all three)

1. **The rootless wall is not a quick fix.** Whether AppArmor (Claude's leading hypothesis), detach-netns (Codex's leading hypothesis), or Ubuntu 24.04 kernel namespace hardening (Gemini's framing) — every diagnosis points at structural friction, not a missing knob. Even if salvageable, ROI for live trading is poor.
2. **The diagnostic the team did was misleading by accident.** Manual `unshare -U -r -n` and `rootlesskit + ip link add brtest` run from an *unconfined login shell*; the rootless daemon runs in a different confinement context. The successful manual tests don't falsify the daemon's failures. The correct discriminator is `dmesg | grep apparmor` + `cat /proc/$(pgrep -x dockerd)/attr/current` — neither was run.
3. **Option (A) — keep fighting — is rejected.** Open-ended timeline against real-money exposure.
4. **Option (C) — "accept partial Phase A and the agent's docker.sock residual" — is rejected.** Naming this "the shortcut" was correct.
5. **IBKR-side controls (sub-account, trusted-IP, daily caps) should move from "Phase C" to immediate.** All three reviewers (most pointedly Claude) note this is the only layer that survives a fully-owned host and it's IBKR-portal config — zero infra hours, no resource competition.

## Disagreement — the architecture question

| Option | Gemini | Codex | Claude |
|---|---|---|---|
| **(B) Local VM on this host** | **Recommended** — KVM/libvirt or Multipass; "hardware-enforced boundary," "agent has zero visibility" | **Recommended** — "the only option that is both architecturally correct and operationally boring" | **Rejected** — "host root owns local VMs too (virsh, the qcow2 on disk, ptrace of the qemu process, the serial console). B buys operational tidiness, not a security boundary against your stated threat." |
| **(D) Remove agent's host-root path + IBKR controls + (optionally) physically-separate host** | Not addressed | Mentioned as "even better but not faster than B" | **Recommended** — "the architecturally correct core, not a residual" |

**Reconciliation:** Claude is technically correct that host root owns local VMs. A local VM does not bind against an actor with host-root reach (which the agent has, via docker.sock mounts). But Gemini and Codex implicitly assume the agent's host-root path is already closed (or never thought about it) — in that frame, B isolates against the next-tier threat (agent without host root).

The honest reading: **B is fine *after* the agent loses host-root reach.** B is meaningless *before* that. So the agent's docker.sock removal isn't an alternative to B — it's a *prerequisite* to B mattering. Claude's framing is right; Gemini/Codex's recommendation is downstream of it.

## What I (the admin's AI) got wrong, named

Surfaced by Claude, confirmed by independent grounding:

1. **I was protecting the wrong layer.** Rootless docker isolates the rootless containers from *unprivileged users*. The agent isn't unprivileged — it holds a docker.sock that gives it root-equivalent on the host. Rootless never could have bound against this threat. I should have re-checked this before spending hours on the daemon.
2. **I introduced a real security cost chasing the dead end.** `kernel.apparmor_restrict_unprivileged_userns=0` (persisted in `/etc/sysctl.d/`) and `/etc/apparmor.d/unprivileged_userns` made `flags=(unconfined)` — both are **global**. They weakened userns restriction for **every container on the host**, including the very agent runtime I'm defending against. Net-negative security change in service of a boundary that didn't bind. **These need to be reverted today.**
3. **Diagnostic confirmation bias.** I over-verified the parts that worked (`CapEff`, manual unshare from unconfined shell) and never ran the discriminating command (`dmesg | grep apparmor`). The "the namespace is capable" test does not prove "the daemon is unconfined." Claude flagged this directly: "dmesg | grep apparmor would have ended this on day one."
4. **The breach window is self-inflicted by sequencing.** Phase A's certain fix was deferred (or executed partially with dev access removal that we then reversed) while pursuing the uncertain rootless path. Live has been reachable from the agent the whole time. **The architecturally correct sequencing was: agent's docker.sock first, IBKR controls second, then any infra isolation as defense-in-depth.**

## Final action list (synthesized; ordered for minimum breach window)

### Step 0 — Right now (2 min, read-only, no breach cost)

Measure actual current exposure:

```bash
getent group docker
docker ps --format '{{.Names}} {{.Mounts}}' | grep docker.sock
docker inspect mcp-ib-live --format '{{json .NetworkSettings.Networks}}'
```

The list of socket-mounting containers is the live attack surface. Every one is host-root-equivalent for any actor who can exec into it.

### Step 1 — Today, 5 min, IBKR portal (zero infra)

On the live IBKR account `U15907310`, set:

- **API trusted-IP allowlist:** restrict to this host's public egress IP only.
- **Sub-account with hard caps:** notional, position, daily loss limits. Cap small enough that worst case loss is acceptable.
- **Daily order count cap:** bounds a runaway loop.

This is the *only* control that survives a fully-owned host. Do this first.

### Step 2 — Today, ~30 min (cuts the agent's host-root path)

- **Remove `/var/run/docker.sock` mount from every agent-runtime container the autonomous agent can reach.** Specifically `agents-cli-claude-websurfinmurf` and `webui-claude-websurfinmurf`. (Other socket holders — `traefik`, `netdata`, `dozzle`, `promtail`, `portainer`, etc. — stay; the agent has no exec path into those.)
- **Recreate those containers** so the change takes effect.
- **Identity split (the Phase 1 recommendation that disappeared from earlier syntheses):** the autonomous agent runs as `websurfinmurf-agent`, a new uid that is **not in `sudo`, not in `docker`, no path to admin's docker.sock**. The human `websurfinmurf` keeps his uid + group memberships for hands-on work. Distinguishes "the human (trusted)" from "the autonomous AI under that identity (constrained)."

This is the actual load-bearing boundary. Once done, the agent cannot reach the rootful daemon and so cannot reach live trading — period — even with the live stack still on the same rootful daemon.

### Step 3 — Today, ~10 min (revert the security regression I introduced)

```bash
# revert host-wide AppArmor weakening
sudo mv /etc/apparmor.d/unprivileged_userns.bak /etc/apparmor.d/unprivileged_userns
sudo apparmor_parser -r /etc/apparmor.d/unprivileged_userns
sudo rm /etc/sysctl.d/99-rootless-docker.conf
sudo sysctl --system | grep apparmor_restrict
# expect: kernel.apparmor_restrict_unprivileged_userns = 1

# stop and disable the (broken, no longer needed) rootless daemon
systemctl --user stop docker.service
systemctl --user disable docker.service
rm -rf ~/.config/systemd/user/docker.service.d/  # the override no longer needed
```

The whole rootless effort gets archived as documented-but-abandoned. No tech debt left behind.

### Step 4 — Today, ~5 min (restore dev workflows)

```bash
sudo gpasswd -a websurfinmurf docker
sudo gpasswd -a joe docker
```

Their dev workflows return. The agent's path to live is now closed by Step 2 regardless of group membership.

### Step 5 — Confirm the breach is actually closed

Run the validation matrix from the prior synthesis (`ib-gateway-running-session-breach.final.md` Phase B), specifically:

- From `mcp-code-executor` (which previously had docker.sock, now doesn't): `docker -H unix:///var/run/docker.sock ps` → fails (no socket).
- From `agents-cli-claude-websurfinmurf` (after recreate without docker.sock): `docker run --network mcp-ib-live-net …` → fails.
- From inside the wrapper test pattern: any `ib_async` attempt against `ibgateway-live:4003` from a container the agent can reach → fails (no network reach without docker socket pivot).

### Step 6 — Defer

- **Separate physical host for live.** If you want a boundary that survives even host-root compromise (the residual after Steps 1+2), a separate machine is the architecturally correct answer. Multi-day setup, not in scope today. Worth scheduling for next week.
- **`developers/ib-gateway` image promotion.** Continues per the existing track. Image is credential-free either way.

## What this synthesis explicitly rejects

- **Continuing rootless on this host.** All three reviewers agree.
- **Local VM (B) as the security answer.** Claude's reasoning holds — host root owns local VMs. Local VM is operationally tidy but doesn't bind against the stated threat. If host root is the residual concern, the answer is *separate host*, not *local VM*.
- **The framing that Phase A is "the shortcut."** That label was wrong. Phase A (socket removal) + identity split + IBKR controls is the architecturally correct core. Rootless was the residual nice-to-have whose load-bearing role was misallocated in earlier docs (including by me).

## What the reviewers explicitly disagreed about that matters

The single substantive disagreement: **whether a local VM (B) is a meaningful boundary**.

Gemini and Codex effectively assume the agent's host-root reach is gone (or don't address it); from that assumption, B isolates against the residual threat. Claude points out the agent still has host-root reach today (the docker socket mount), and host root owns local VMs trivially, so B buys nothing security-wise against the actual current attacker.

If Step 2 (remove the agent's docker.sock mounts) is executed first, the disagreement evaporates: at that point, B is fine as defense-in-depth, but no longer necessary as the load-bearing boundary. **The sequence matters more than the option.**

## Risks flagged (residual after the action list)

- **Host root still reads `TWS_PASSWORD` from `/proc/<pid>/environ`** — this is the prior threat-model call (accepted) and unchanged. IBKR-side controls are the only mitigation.
- **Image supply chain.** The live container's bytes are still locally-built from `../ib`. `developers/ib-gateway` work is in flight; admin diff-review remains the gate.
- **Kernel 6.17 vs Docker's tested 6.8 Noble target.** If we ever re-attempt rootless, this is a likely contributing factor to the wall.
- **A separate host eventually.** A reasonable defense-in-depth goal once Steps 1–5 are done. Don't let it become "later."

---

## Execution log — 2026-06-04

Steps 0, 2, 3, 4, 4.5, 5 executed today. Final state:

- **Step 0 (measurement)** — captured: 11 docker.sock-mounting containers; live wrapper still on `mcp-net` + `traefik-net` (Phase A compose change had been on disk but not applied — running container was 31h old); websurfinmurf NOT in docker, joe IS in docker, sudoers NOPASSWD line gone.
- **Step 2 (close docker.sock paths)** — edited `~/projects/agents/cli/claude/websurfinmurf/docker-compose.yml` and `~/projects/webui-claude/websurfinmurf/docker-compose.yml`: removed `group_add: ["127"]` block + `/var/run/docker.sock:/var/run/docker.sock:ro` mount on both. Redeployed via project deploy scripts (`./deploy.sh websurfinmurf --deploy-only`) to source secrets correctly. Verified: socket mount gone, agent's effective groups = `1000(websurfinmurf)` only, container can't reach docker daemon at any path. Admin variants (`agents-cli-claude-administrator`, `webui-claude-administrator`) NOT touched — admin's discretion.
- **Step 3 (revert AppArmor regression)** — restored `/etc/apparmor.d/unprivileged_userns` from `.bak`, reloaded; removed `/etc/sysctl.d/99-rootless-docker.conf`; confirmed `kernel.apparmor_restrict_unprivileged_userns = 1` (back to Ubuntu default). Tore down rootless docker: `systemctl --user stop/disable docker.service`, removed `~/.config/systemd/user/docker.service.d/` and `~/.config/docker/`.
- **Step 4.5 (apply Phase A compose to live)** — `CONFIRM_LIVE=yes start-gateway` recreated `mcp-ib-gateway-live` + `mcp-ib-live`. Caught a lingering shell-env issue: `DOCKER_HOST=unix:///run/user/2000/docker.sock` was still exported from the rootless attempts; `unset DOCKER_HOST` fixed it. Post-recreate: both containers on **only `mcp-ib-live-net`**. No more `mcp-net` / `traefik-net` joins. No host port publishes.
- **Step 4 (restore docker access)** — `sudo gpasswd -a websurfinmurf docker` + `sudo gpasswd -a joe docker`. Dev workflows return on the rootful daemon.
- **Step 5 (validate)** — from inside `agents-cli-claude-websurfinmurf` as the autonomous agent:
  - T1 socket mount: **ABSENT** ✓
  - T2 docker daemon reach: **exit=7 (connect refused)** ✓
  - T3 docker CLI: **not installed** ✓
  - T4 mcp-net pivot to wrapper: **exit=6 (DNS resolution fails)** ✓ (wrapper no longer on mcp-net)
  - T5 proxy pivot: **exit=22 (route not found)** ✓
  - T6 legit admin → wrapper /health: **healthy** ✓ (legit path preserved)

## What remains open

- **T7 (live U-account proof)** — running at time of writing; IBC re-authenticating to the live account, may need 2FA approval on phone. Expect `accounts: ['U15907310']` once login completes; that confirms the live wrapper → live gateway path still works (the admin's legit channel).
- **Step 1 (IBKR-side controls)** — still admin's portal task: trusted-IP allowlist on `U15907310`, sub-account with hard notional/position/daily-loss caps, daily order count cap. Only layer that survives a fully-owned host. Not done today; on admin's list.
- **Admin-side agent containers** (`agents-cli-claude-administrator`, `webui-claude-administrator`) still mount docker.sock. Admin's own trust model; out of scope for the demonstrated-breach fix.
- **`mcp-ib-paper` wrapper** still mounts docker.sock (for `/gateway/reconnect`). Tracked separately; not load-bearing for the live-trading breach.
- **Developer-side mirror** (`developers/ib-gateway` image, Bitwarden invite confirmation, GitLab repo) — independent work track, not affected by this fix.
