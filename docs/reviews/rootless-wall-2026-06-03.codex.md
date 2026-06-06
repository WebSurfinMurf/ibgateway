---
source: codex
reviewed: 2026-06-03
context: rootless-wall-2026-06-03.md
---

1. The blockers are in Docker's own rootless code paths, not in your `subuid`/`newuidmap` basics.

For AppArmor, the failure is straightforward. `dockerd` calls `loadDefaultAppArmorProfileIfMissing()`, which calls `aaprofile.IsLoaded("docker-default")`, and that function literally opens `/sys/kernel/security/apparmor/profiles`. On Ubuntu/AppArmor, reading that file is policy-admin mediated; historically it required `CAP_MAC_ADMIN`, and AppArmor upstream explicitly treats full profile introspection as policy-admin-only. A rootless daemon only has caps in its own user namespace, not in the initial user namespace, so the open gets `EACCES`. Your edits to `/etc/apparmor.d/unprivileged_userns` do not fix that path. They only affect whether `rootlesskit` can create user namespaces. Docker's own rootless docs still list `AppArmor` as unsupported.

For bridge networking, the failing path is `daemon/libnetwork/drivers/bridge`. On network creation it queues:
- `setupDevice`: `netlink.LinkAdd()` for the bridge
- `setupDefaultSysctl`: write `/proc/sys/net/ipv6/conf/<bridge>/accept_ra`
- `setupMTU`: `netlink.LinkSetMTU()` on the bridge
- then IPv4/IPv6 setup and `LinkSetUp()`

Your logs map exactly to those functions:
- `unable to disable IPv6 router advertisement` = `setupDefaultSysctl`
- `Failed to set bridge MTU docker0 via netlink: operation not permitted` = `setupMTU`

The important miss in the original debugging is that the manual test proved only `ip link add brtest type bridge`, not the two operations Docker is actually dying on: bridge MTU set and per-interface sysctl write. So "manual bridge create works" does not falsify the Docker failure.

There is also a version/path issue here. Current Moby source has explicit detached-rootless handling:
- `dockerd-rootless.sh` defaults `DOCKERD_ROOTLESS_ROOTLESSKIT_DETACH_NETNS=true`
- current `daemon/apparmor_linux.go` disables AppArmor entirely when detached netns is present
- current bridge driver has rootless detached-netns plumbing

Your reported `29.1.3` behavior looks like you are on the wrong side of those fixes, or detach-netns is active without the corresponding AppArmor/bridge accommodations being effective in that build.

2. I would stop fighting rootless on this host for the live stack.

The one decisive experiment still worth 5 minutes, if you want to prove me wrong before abandoning it, is this single change:

```ini
# ~/.config/systemd/user/docker.service.d/override.conf
[Service]
Environment=DOCKERD_ROOTLESS_ROOTLESSKIT_DETACH_NETNS=false
```

Then:

```bash
systemctl --user daemon-reload
systemctl --user restart docker
DOCKER_HOST=unix:///run/user/2000/docker.sock docker run --rm --security-opt apparmor=unconfined hello-world
DOCKER_HOST=unix:///run/user/2000/docker.sock docker network create rootless-test
journalctl --user -u docker.service -b --no-pager | tail -n 200
```

Why this is the best single test:
- current Moby treats detached netns as the AppArmor-inaccessible mode
- it also removes one whole class of detached-netns/libnetwork mismatches
- it tells you quickly whether this is a detach-netns/version bug vs. a hard host limitation

If that does not immediately clear the wall, stop. Do not spend the day trying random combinations of `vpnkit`, `iptables-legacy`, or AppArmor profile edits around a real-money gateway.

3. Architecture: `B` is the right answer.

Use a small VM on this host and run normal rootful Docker inside the VM.

Why:
- It actually closes the reach from the developer agent's host `docker.sock`.
- It avoids rootless Docker's documented AppArmor limitation.
- It gives you ordinary bridge networking, normal Compose behavior, and predictable debugging.
- It is the only option here that is both architecturally correct and operationally boring.

I would reject:
- `A` as the recommendation. Rootless may be salvageable, but not with enough confidence for a live IBKR gateway on this host/version combo.
- `C` outright. That is the shortcut you already identified as the anti-pattern.
- `D` only if you mean "a physically separate host" or "a dedicated VM on another machine," which is even better but not faster than `B`.

4. What I would do in the next 10 minutes as operator:

First, close the breach window now:

```bash
cd /home/administrator/projects/mcp/ib-live
docker compose down
docker ps --format '{{.Names}}\t{{.Networks}}' | egrep 'mcp-ib-live|mcp-ib-gateway-live|mcp-ib-live-net'
```

Then pick one of two paths, and only one:

If you want the last falsification test before moving on:
```bash
mkdir -p ~/.config/systemd/user/docker.service.d
printf '[Service]\nEnvironment=DOCKERD_ROOTLESS_ROOTLESSKIT_DETACH_NETNS=false\n' > ~/.config/systemd/user/docker.service.d/override.conf
systemctl --user daemon-reload
systemctl --user restart docker
DOCKER_HOST=unix:///run/user/2000/docker.sock docker run --rm --security-opt apparmor=unconfined hello-world
DOCKER_HOST=unix:///run/user/2000/docker.sock docker network create rootless-test
```

If either command fails, stop rootless work and build the VM.

If you want the path I would actually take:
```bash
sudo apt-get update
sudo apt-get install -y qemu-kvm libvirt-daemon-system virtinst cloud-image-utils
```

Then create a small Ubuntu VM, move the live Compose stack into it, and only expose what you need over SSH or a tight VM-local ingress path. No shared Docker socket. No shared host network namespace. No shared host mounts unless unavoidable.

Sources:
- Docker rootless troubleshooting and known limitations: https://docs.docker.com/engine/security/rootless/troubleshoot/
- Moby AppArmor rootless handling: https://raw.githubusercontent.com/moby/moby/master/daemon/apparmor_default.go
- Moby AppArmor support check in rootless detached netns: https://raw.githubusercontent.com/moby/moby/master/daemon/apparmor_linux.go
- Moby rootless launcher defaulting `DOCKERD_ROOTLESS_ROOTLESSKIT_DETACH_NETNS=true`: https://raw.githubusercontent.com/moby/moby/master/contrib/dockerd-rootless.sh
- Moby AppArmor profile lookup opening `/sys/kernel/security/apparmor/profiles`: https://raw.githubusercontent.com/moby/profiles/main/apparmor/apparmor.go
- Ubuntu/AppArmor note on `/sys/kernel/security/apparmor/profiles` requiring policy-admin semantics: https://bugs.launchpad.net/ubuntu/+source/linux/+bug/1560583
- Moby bridge setup code doing `LinkSetMTU` and `accept_ra` write: https://raw.githubusercontent.com/moby/moby/master/daemon/libnetwork/drivers/bridge/setup_device_linux.go
