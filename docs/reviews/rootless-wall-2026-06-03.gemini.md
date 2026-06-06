---
source: gemini
reviewed: 2026-06-03
context: rootless-wall-2026-06-03.md
---

### 1. Diagnosis of the Failures

**AppArmor Profile Check (`Failure 2`)**
This fails because Docker doesn't realize it is running in a rootless environment. In the `containerd/apparmor.HostSupports()` code path, Docker checks if it should enforce AppArmor by verifying if `/sys/module/apparmor/parameters/enabled` is `Y` AND `os.Getenv("container") == ""`. Because `dockerd-rootless.sh` launched via systemd does not set the `container` environment variable by default, Docker assumes it is on a standard host. It attempts to call `os.Open("/sys/kernel/security/apparmor/profiles")` to check for `docker-default`. Because rootless docker runs in an unprivileged user namespace, `securityfs` is restricted (`0400` root-only on the host), resulting in `EACCES` (permission denied) and blocking container startup.

**Bridge Driver and Sysctl Failures (`Failure 1 & 3`)**
These fail due to Linux kernel restrictions on unprivileged user namespaces, regardless of the `apparmor_restrict_unprivileged_userns=0` setting.
- When libnetwork attempts to configure the bridge interface (`docker0` or `rootless-test`), it executes a netlink `RTM_NEWLINK` message with `IFLA_MTU` to set the MTU, and attempts to write `0` to `/proc/sys/net/ipv6/conf/<bridge>/accept_ra`. Even inside the `slirp4netns` network namespace, the unprivileged userns lacks the capabilities to alter the bridge MTU beyond the parent interface's bounds or write to specific restricted network sysctls, returning `EPERM`.
- Furthermore, user-defined networks (Failure 1) completely ignore the `daemon.json` `"iptables": false` setting. Libnetwork implicitly attempts to insert NAT rules using `iptables-nft`. Unprivileged namespaces on Ubuntu 24.04 lack netfilter permissions by default, causing the `operation not permitted` error.

### 2. Keep fighting or move on?

**Move on.** Do not keep fighting rootless docker on this host.

While you *could* hack past the AppArmor check by injecting `Environment="container=rootlesskit"` into your systemd unit, fixing the libnetwork bridge failures would require forcing host-level MTU restrictions or abandoning user-defined compose networks entirely. Ubuntu 24.04 enforces aggressive kernel and AppArmor security models specifically targeting unprivileged namespaces. Rootless docker here is structurally brittle. Every future kernel patch or AppArmor reload risks breaking the live gateway. You are defending real money against an active breach window; fighting these kernel quirks is a dangerous distraction.

### 3. Recommended Architecture

**(B) Provision a small VM on this host.**

A lightweight VM (e.g., via Multipass or KVM/libvirt) provides a clean, hardware-enforced boundary. Inside the VM, you run a standard, **rootful** Docker daemon. The live IB gateway and wrapper compose network will function perfectly with native iptables, bridge drivers, and AppArmor. The autonomous agent running on the host's rootful daemon has zero visibility or access to the VM's socket or internal network. This perfectly satisfies the architectural security requirement ("daemon the developer's runtime cannot see") without the userns/AppArmor fragility of rootless mode.

### 4. What I'd do in the next 10 minutes

I would immediately abandon the rootless setup to close the breach window and migrate the live gateway to a VM.

Execute these concrete steps:

1. **Kill the broken rootless environment:**
   ```bash
   systemctl --user stop docker.service
   systemctl --user disable docker.service
   ```
2. **Stop the exposed live gateway on the host to close the breach window:**
   ```bash
   docker compose -f /home/administrator/projects/mcp/ib-live/docker-compose.yml down
   ```
3. **Provision a lightweight VM (using Multipass, standard on Ubuntu):**
   ```bash
   multipass launch --name ib-live --cpus 2 --memory 2G --disk 10G 24.04
   ```
4. **Install rootful docker inside the VM:**
   ```bash
   multipass exec ib-live -- curl -fsSL https://get.docker.com | sh
   ```
5. **Migrate the compose files and start the gateway cleanly:**
   ```bash
   multipass transfer -r /home/administrator/projects/mcp/ib-live ib-live:/home/ubuntu/
   multipass exec ib-live -- sudo docker compose -f /home/ubuntu/ib-live/docker-compose.yml up -d
   ```
6. **Restore developer workflows on the host daemon:**
   ```bash
   sudo usermod -aG docker websurfinmurf
   sudo usermod -aG docker joe
   ```
