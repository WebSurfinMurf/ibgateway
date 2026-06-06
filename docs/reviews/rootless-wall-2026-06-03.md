---
name: rootless-wall-2026-06-03
created: 2026-06-03
status: pending-review
extends: ib-gateway-running-session-breach.final.md
---

# Stuck on rootless docker for live IB gateway. Independent investigation requested.

## What this is

We accepted the running-session breach review board's recommendation: **move the live IB gateway and live MCP wrapper to a rootless docker daemon under administrator's uid, so the developer's autonomous AI agent (which runs in a container on the host's rootful daemon and mounts `/var/run/docker.sock`) cannot reach the live network even with full docker daemon control.** The architectural target was clean: live containers + network exist on a daemon the developer's runtime cannot see.

We've made progress but hit a wall that we'd like each of you to investigate **independently**. Each of you should reach your own conclusion on (a) what's actually blocking us, (b) whether to keep trying to fix rootless here vs. switch architectures, and (c) what specific next step you'd take. I will correlate after.

## Host context

- Ubuntu 24.04.3 LTS, kernel 6.x.
- Docker rootful daemon at `/var/run/docker.sock` is running and hosts ~60+ containers (shared MCP infrastructure, all dev/admin webui and agent runtimes, paper IB gateway+wrapper, observability, Traefik, etc.). We are not disrupting this.
- Live IB gateway compose at `/home/administrator/projects/mcp/ib-live/docker-compose.yml` is already hardened per the prior breach-review (no host port publishes, only `mcp-ib-live-net`, no shared bus joins).
- AppArmor sysctl is set: `kernel.apparmor_restrict_unprivileged_userns = 0` (persisted via `/etc/sysctl.d/99-rootless-docker.conf`).
- `/etc/apparmor.d/unprivileged_userns` was modified to `flags=(unconfined)` and reloaded with `apparmor_parser -r`. (Backup at `unprivileged_userns.bak`.)
- `/etc/sudoers.d/administrators` had its `websurfinmurf ALL=(administrator) NOPASSWD: ALL` line removed.
- `websurfinmurf` and `joe` were temporarily removed from the `docker` group; admin has decided to restore them once the daemon split is in place (their dev workflows require docker).
- `administrator`: uid 2000, in `administrators` group, `docker` group, has linger enabled, `XDG_RUNTIME_DIR=/run/user/2000`.
- subuid/subgid for administrator: `administrator:296608:65536` (standard).
- `newuidmap` / `newgidmap`: `-rwsr-xr-x root root` (setuid bit present).
- `/etc/docker/daemon.json` (rootful) contains `default-address-pools` + `insecure-registries` only.

## What we have working

- **Rootless docker daemon installed and active** under administrator (`systemctl --user is-active docker.service` → `active`). Docker 29.1.3, socket at `/run/user/2000/docker.sock`.
- **Systemd user unit drop-in** at `~/.config/systemd/user/docker.service.d/override.conf` setting `ExecStart=/usr/bin/dockerd-rootless.sh --config-file=/home/administrator/.config/docker/daemon.json`.
- **Daemon config** at `~/.config/docker/daemon.json`:
  ```json
  {
    "iptables": false,
    "ip6tables": false,
    "bridge": "none"
  }
  ```
  We added these one by one as we hit issues. `iptables`/`ip6tables` false because rootless+nftables+Ubuntu 24.04 has known iptables permission errors. `bridge: none` because the default `docker0` bridge creation failed even with iptables disabled.
- **From inside `rootlesskit --net=slirp4netns --copy-up=/etc --copy-up=/run --propagation=rslave sh -c '…'`**, a sanity test confirms:
  - `CapEff: 000001ffffffffff` (full caps in the rootless namespace).
  - `ip link add brtest type bridge` succeeds.
  - `ip link set lo mtu 1500` succeeds.
  - `ip6tables -t nat -N TEST` succeeds.
- **Manual `unshare -U -r -n …`** from administrator's shell: bridge create, ip6tables NAT chain create — all OK.
- The dockerd-rootless launches; `docker network ls` from `DOCKER_HOST=unix:///run/user/2000/docker.sock` returns the default `host` and `none` networks.

## Where we're stuck (the actual failure modes)

### Failure 1 — `docker network create rootless-test` from the rootless daemon returns:

```
Error response from daemon: operation not permitted
```

This is from libnetwork's bridge driver trying to create a user-defined bridge network. Same operation that works manually inside rootlesskit. The dockerd log doesn't add much detail beyond the netlink/sysctl errors below.

### Failure 2 — `docker run --rm hello-world`:

```
docker: Error response from daemon: Could not check if docker-default AppArmor profile was loaded:
open /sys/kernel/security/apparmor/profiles: permission denied
```

Dockerd tries to verify the `docker-default` AppArmor profile is loaded before starting a container. Inside the rootless namespace it can't read `/sys/kernel/security/apparmor/profiles` (securityfs).

### Failure 3 — When daemon starts, journal shows (warnings/errors that may be related):

```
level=warning msg="unable to disable IPv6 router advertisement"
    error="open /proc/sys/net/ipv6/conf/docker0/accept_ra: permission denied"
level=error msg="Failed to set bridge MTU docker0 via netlink"
    error="operation not permitted"
... eventually:
failed to start daemon: Error initializing network controller:
    error creating default "bridge" network: operation not permitted
```

(With `bridge: none` set in daemon.json, the daemon stops failing at this point and continues to a working state — but bridge networks remain uncreatable by user request.)

### What we have NOT yet tried

- `DOCKERD_ROOTLESS_ROOTLESSKIT_DETACH_NETNS=0` (we attempted to add it via systemd override but the paste mangled and we never confirmed the env var was set; if you think this is decisive, name it).
- `DOCKERD_ROOTLESS_ROOTLESSKIT_NET=vpnkit` (alternative network backend).
- Downgrading Docker (29.1.3 → 25.x or 26.x).
- Switching system iptables to `iptables-legacy` (would require restarting all 60+ rootful containers — disruptive enough that we'd rather not unless someone says it's the decisive fix).
- `--security-opt apparmor=unconfined` on a per-container basis.
- Adding `allow capability,` to `/etc/apparmor.d/local/unprivileged_userns` (the override would be loaded by the parent profile's `include if exists <local/unprivileged_userns>` line). We haven't tested whether this overrides the parent's `audit deny capability` — AppArmor's deny-precedence rules make us uncertain.

## What I want from you (each, independently)

You each have access to the same context. **Do not coordinate. Investigate independently. Reach your own conclusion.** I will correlate after.

1. **Diagnose the failures.** What's actually preventing the bridge driver and AppArmor profile check from working in this rootless setup? Be specific — kernel, AppArmor profile content, Docker libnetwork code path, anything.

2. **Tell me whether to keep trying to fix rootless on this host.** If yes, what's the one most-decisive next thing to try (with reasoning). If no, why is rootless structurally broken on this combination.

3. **Tell me what the right architecture is, given what you find.** Options as we see them:
   - **(A) Keep fighting rootless docker on this host.** If you think there's a decisive fix in 1-2 more steps, name it.
   - **(B) Provision a small VM on this host (KVM/libvirt or LXD or Multipass) for live, run normal rootful docker inside it.** Live network lives in the VM. The rootful daemon on this host can't see it. ~1-2 hours.
   - **(C) Accept partial Phase A** (compose isolation + sudoers fix), restore websurfinmurf/joe to docker, and explicitly leave the agent-runtime docker.sock as an unsatisfactory residual until later. (Acknowledge: the user's stated frame is "later doesn't exist" — this option is the shortcut and they have explicitly named it as an anti-pattern.)
   - **(D) Something else we haven't considered.**

4. **What you'd do as the operator.** If you owned this account and this host, what's the next concrete action you'd take in the next 10 minutes.

## Constraints / things to know

- User is a 40-year IT architect. He has explicitly named "shortcut now, fix later" as an anti-pattern and asked us to stop proposing it. The architecturally correct answer is the recommendation; alternatives are alternatives, not "recommended."
- Live IB account `U15907310` is real money. The reach the agent demoed (via `docker run --network mcp-ib-live-net …`) was read-only by his choice; it could have been order placement.
- Currently `mcp-ib-gateway-live` and `mcp-ib-live` are running on the rootful daemon, fully functional, but the breach reach is wide open. Every minute of debugging is a minute of exposure.
- We have time pressure but not crisis pressure. Markets are open today; autotrade is off; manual trading from this account works.

Be direct. Cite specific commands or file contents we should check or change. If you need a piece of information to be sure, name it explicitly so we can paste it back.
