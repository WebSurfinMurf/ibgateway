---
source: codex
reviewed: 2026-06-02
context: ib-gateway-cred-protection.md
---

**Findings**

1. **There is no real secret-protection architecture on this host as currently trusted.** The memo is correct at [ib-gateway-cred-protection.md](/workspace/administrator/projects/ibgateway/docs/reviews/ib-gateway-cred-protection.md:50): if the developer account keeps `docker` access, any scheme that eventually places live creds into a running container is broken. `env_file`, Docker secrets, Vault sidecars, TPM-unseal, startup prompts, and encrypted blobs all collapse once that account can `docker inspect`, `docker exec`, or bind-mount the host. The proposed "encrypted at rest + runtime trust" design in [ib-gateway-cred-protection.md](/workspace/administrator/projects/ibgateway/docs/reviews/ib-gateway-cred-protection.md:67) is not a secrecy boundary. It is only an at-rest hygiene measure.

2. **The real boundary you want is privilege separation, not better secret wrapping.** For your stated threat model in [ib-gateway-cred-protection.md](/workspace/administrator/projects/ibgateway/docs/reviews/ib-gateway-cred-protection.md:76), the dangerous permission is `docker` more than `sudo`, because `docker` is typically passwordless and scriptable by an AI agent. If the goal is "the developer-side agent cannot exfiltrate live creds unless the human explicitly chooses to," then the developer account cannot have ambient access to the live container runtime or its storage.

3. **"Temporarily remove from docker group during live session" is brittle and not a good operating model.** It is easy to forget, group changes do not reliably revoke already-open sessions, and it creates weird state-dependent behavior that is hard to audit. That is not a clean boundary.

4. **There is a separate deployment-integrity problem in the live scaffold.** The live compose still builds locally and uses mutable images: [docker-compose.yml](/workspace/administrator/projects/mcp/ib-live/docker-compose.yml:5) builds `../ib`, and [docker-compose.yml](/workspace/administrator/projects/mcp/ib-live/docker-compose.yml:35) uses `ghcr.io/gnzsnz/ib-gateway:latest`. That is a supply-chain/reproducibility risk independent of secrets. Live should consume pinned, promoted artifacts only.

**Assessment**

The honest answer is: no, there is no defensible in-band scheme on the shared rootful Docker host while the developer account retains access to that Docker daemon. If you keep that setup and say "the developer cannot read the live creds," that is false.

The design you currently lean toward is defensible only if you rename the claim. It can honestly mean: "the live creds are not stored in plaintext at rest, and an automated compromise of the developer repo alone is insufficient." It cannot mean: "the developer-side account/agent on this host cannot read the live creds."

**What I'd do differently**

I would split the trust boundary at the runtime level, not at the secret format level.

Best option on one physical box: run live inside an **admin-only VM** on that same host. Dev keeps using the host Docker daemon for paper. Admin deploys live by pulling a pinned image digest into the VM. That gives you a real boundary without needing another physical machine.

If you do not want a VM, second-best: run live under an **admin-only rootless engine** or admin-only service account, and remove `websurfinmurf` from the host Docker group permanently. That is good enough for your stated "AI agent on the developer side" threat model, assuming `sudo` is not passwordless and the admin password is not available to the agent.

I would not spend more time on encrypted env files, DB-backed key stores, or audit-logged retrieval unless you first fix the runtime boundary.

**Specific suggestions with rationale**

- **Choose one of these two architectures and commit to it:**
  - Admin-only VM for live.
  - Admin-only rootless container runtime with the developer removed from `docker`.
  Rationale: both create a real boundary against non-interactive credential exfiltration by the developer-side agent.

- **Make live deploy pull-only and immutable.**
  - Do not `build` in live.
  - Do not use `:latest`.
  - Deploy pinned tags or, better, image digests.
  Rationale: live promotion should be "admin approves artifact X," not "admin rebuilds whatever is on disk today." Current live files at [docker-compose.yml](/workspace/administrator/projects/mcp/ib-live/docker-compose.yml:5) and [deploy.sh](/workspace/administrator/projects/mcp/ib-live/deploy.sh:27) do not meet that bar.

- **Keep secrets simple once the boundary is real.**
  - Admin-owned env file or secret file is fine.
  - Optional passphrase-decrypt-at-start is fine for at-rest hygiene.
  Rationale: after separation, `env_file` is not the main problem anymore. Do not overengineer secret handling inside a trustworthy admin-only runtime.

- **Do not give the live wrapper access to `docker.sock`.**
  - In paper, the wrapper mounts `/var/run/docker.sock` in [mcp/ib-paper/docker-compose.yml](/workspace/administrator/projects/mcp/ib-paper/docker-compose.yml:21).
  - Do not carry that pattern into live.
  Rationale: a mounted Docker socket is effectively host control; `:ro` does not make it safe in practice for a Unix socket. If you need restarts, let `systemd` or the VM supervisor manage them.

- **Bind live ports to localhost or a restricted interface only.**
  - Especially VNC and the IB API ports in [docker-compose.yml](/workspace/administrator/projects/mcp/ib-live/docker-compose.yml:49).
  Rationale: reducing network exposure matters as much as file secrecy here. Use SSH tunneling for admin VNC instead of broad LAN exposure.

- **Treat the live JTS/IBC state directories as sensitive artifacts too.**
  - The mounted `./jts` and `./ibc` paths in [docker-compose.yml](/workspace/administrator/projects/mcp/ib-live/docker-compose.yml:53) may contain remembered settings, trusted-device state, or other reusable material.
  Rationale: protecting only `TWS_PASSWORD` but not the persisted runtime state is incomplete.

**Risks / gotchas you may be missing**

- **Group removal is not an instant revoke.** Existing sessions can retain supplementary groups until logout/session restart. If you ever change group membership as a control, assume you need a full session reset.

- **The human and the developer are the same person.** That means your boundary is really "against automation without explicit human consent," not "against the human." That is fine, but be precise. It changes which controls are worth paying for.

- **Audit logs are not preventive control.** Postgres logging of secret retrieval tells you what happened after the fact. It does not stop exfiltration, and a sufficiently privileged actor may tamper with logs.

- **Runtime exposure window matters.** If the live gateway is long-running, "prompt for the passphrase at startup" buys very little. The real secret exposure period is the whole uptime of the live session.

- **Shared-kernel rootless isolation is weaker than VM isolation.** For your home-lab threat model, rootless is probably enough. If you want the clearest story and fewest caveats, use a VM.

My recommendation is straightforward: **do not keep live on the shared rootful Docker daemon.** Use an admin-only VM if you want the cleanest answer; use an admin-only rootless runtime if you want the cheapest acceptable answer. After that, simplify secret handling and tighten deploy immutability.
