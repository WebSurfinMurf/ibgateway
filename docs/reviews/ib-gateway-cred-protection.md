---
name: ib-gateway-cred-protection
created: 2026-06-02
status: pending-review
---

# Credential protection for a live IB Gateway on a shared host where a developer has docker-group access

## Situation

We are about to stand up an Interactive Brokers **live** Gateway container on a single home-lab host (`linuxserver.lan`) for a personal algorithmic-trading project. The IBKR live login is high-value: anyone with the username + password + 2FA-acknowledged session can place real-money orders against this account.

The setup follows a developer/administrator split:

- **Developer** (AI agent `websurfinmurf` + a human user `websurfinmurf`) — owns the gateway Docker image (a thin wrapper over `ghcr.io/gnzsnz/ib-gateway:10.41.1e`), builds versioned tags, runs the **paper** gateway end-to-end with his own paper IBKR login.
- **Administrator** (this account) — owns the live IBKR account credentials, runs the live gateway from the developer's promoted image with admin-only secrets, never lets the developer see live creds.

The credentials boundary is meant to be: dev image is credential-free; admin injects creds at runtime from `~administrator/projects/secrets/ib-gateway-live.env` (mode 600); image + repo never contain real secrets.

**The complication**: the developer's Linux user is in the `docker` group AND the `sudo` group on this same host:

```
$ id websurfinmurf
uid=1000(websurfinmurf) gid=1000(websurfinmurf) groups=1000(websurfinmurf),4(adm),24(cdrom),27(sudo),30(dip),46(plugdev),100(users),114(lpadmin),127(docker),3000(developers),3001(tmuxshare)

$ getent group docker
docker:x:127:websurfinmurf,joe,administrator
```

This breaks the "I never see live creds" claim of the proposal in multiple ways:

1. `docker inspect mcp-ib-gateway-live` — reveals all env vars set via `env_file:`, in cleartext (`TWS_USERID`, `TWS_PASSWORD`, `VNC_SERVER_PASSWORD`).
2. `docker exec mcp-ib-gateway-live env` — same.
3. `docker run --user 0 -v /home/administrator:/x:ro alpine cat /x/projects/secrets/ib-gateway-live.env` — docker-group access lets him read any file on the host as root-inside-container, defeating mode-600 file perms.
4. `sudo cat ~administrator/projects/secrets/ib-gateway-live.env` — sudo defeats file perms directly.

The IB Gateway itself is a closed Java app (we don't control its source). It expects `TWS_USERID` / `TWS_PASSWORD` from env vars at startup via IBC's config.ini envsubst path. It has no API for "give me an encrypted blob + a key locator."

## Relevant Code / Config

- Proposal we're operating under: `/workspace/aichat/ib-gateway-ownership-proposal.md`
- Live-deploy directions from dev: `/workspace/aichat/ib-gateway-live-deploy.md`
- Live secrets skeleton (currently): `/workspace/administrator/projects/secrets/ib-gateway-live.env` (mode 600, owner administrator, contains TWS_USERID + TWS_PASSWORD + VNC_SERVER_PASSWORD + trading mode + ports)
- Existing live wrapper scaffold (admin-owned, currently misconfigured to paper-mode placeholders): `/workspace/administrator/projects/mcp/ib-live/`
- Existing paper deployment we just hardened (admin-owned, stopped pending dev hand-over): `/workspace/administrator/projects/mcp/ib-paper/` (see `troubleshooting.md` for the durability work landed 2026-05-30/31: `AUTO_RESTART_TIME=03:00 AM`, `SAVE_TWS_SETTINGS=00:30 Every Day`, `EXISTING_SESSION_DETECTED_ACTION=primary`, `RELOGIN_AFTER_TWOFA_TIMEOUT=yes`, plus a `live_probe()` wrapper-side and a 5-minute startup grace period for the wrapper's gateway-restart logic).
- Wrapper code (admin-owned): `/workspace/administrator/projects/mcp/ib/src/server.py`

## What I Need

We want substantive feedback on the credential-protection design. Specifically:

1. **Is there a defensible architecture under which the developer truly cannot read the live IBKR credentials, without paying a ridiculous operational cost?** "Defensible" meaning: the boundary survives `docker inspect`, `docker exec`, `docker run -v /:/host alpine`, and `sudo`. We've considered:
   - Encryption-at-rest with key from disk → broken by docker-group bind-mounts.
   - Key in app DB → chains the problem (postgres URL becomes the new secret to leak).
   - Docker Swarm secrets / `/run/secrets/` tmpfs → broken by `docker exec` of anyone in docker group.
   - Vault agent sidecar → bootstrap auth is the new secret; same shape.
   - TPM-sealed unseal → adds real complexity, doesn't stop `docker exec` once container is running.
   - Interactive prompt at startup (admin types creds at `read -s`) → no at-rest leak, but cleartext is in container env afterwards, so docker-group can still read at runtime.
   - **Removing `websurfinmurf` from the `docker` group on this host** → real boundary; breaks his ability to run his own paper container here.
   - **Separate host / VM for live gateway** → real boundary; needs another machine.
   - **Rootless docker daemon under administrator** → real boundary; rootless has networking quirks (privileged ports, network namespacing).

2. **If no in-band scheme is real, what's the cleanest hybrid?** For example: live runs under rootless docker as admin-only, dev image is built/tested in the main daemon as paper, image is pulled from the registry by the rootless daemon. Or: live runs on a separate cheap host. Or: live runs on this host but at deploy time we kick websurfinmurf out of docker group for the duration of the live session, restore after.

3. **Threat-model question**: how seriously should we treat the runtime exposure threat? The "developer" here is an AI agent + the same human who owns the live IBKR account (it's his own money). The adversarial-AI-agent-exfiltrates-creds scenario is a real concern but the human is also the beneficiary of the credentials. Does that change anything, or is the at-rest + audit-trail boundary actually enough in practice?

4. **Concretely**: is the design we currently lean toward — *"accept runtime trust on this host; protect at-rest with admin-owned encrypted-by-passphrase file the admin types each gateway start; add postgres audit logging for any future key-store retrieval"* — defensible, or is it security theater that should be replaced with the simpler "remove websurfinmurf from docker group and just use env_file" answer?

## Constraints

- **Host**: single home-lab box `linuxserver.lan`, Ubuntu 24.04, Docker rootful default. Adding a second host is possible (we could repurpose an old machine or run a VM) but not free.
- **The IB Gateway is a closed Java app**. We are not patching IBKR's binary or IBC's source. Any encryption layer is in the *startup script* around the container, not in the gateway itself.
- **Two services consume the credentials at runtime**:
  - `mcp-ib-gateway-live` (the IB Gateway container) — needs `TWS_USERID`/`TWS_PASSWORD` to log into IBKR; needs `VNC_SERVER_PASSWORD` to set up the VNC server (used only by admin for one-time settings UI work).
  - The same image also needs to be able to load the durability env vars (`AUTO_RESTART_TIME`, etc.) which are NOT secrets and can live in the compose file.
- **The developer is also the human user**. He's not adversarial; the goal is enforced separation so that if his AI agent goes off the rails (prompt injection, model misbehavior, etc.) it cannot exfiltrate live trading creds without him explicitly choosing to. So the threat model is roughly: "automated/AI compromise of the developer side, not human attack."
- **Reproducibility matters**: the design should still let the dev iterate on the gateway image without admin involvement on every change, and let admin promote a tag to live with a single repeatable command.
- **2FA on the live IBKR account**: separate problem we'll handle (IB Key on phone). Not in scope for this review.
- **CI/registry**: dev's GitLab CI builds and pushes tagged images. The image itself must remain credential-free regardless of which design we choose.

We want a recommendation that is honest about what each option actually buys, not a security-theater answer.
