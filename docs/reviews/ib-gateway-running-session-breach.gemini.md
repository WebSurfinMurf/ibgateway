---
source: gemini
reviewed: 2026-06-03
context: ib-gateway-running-session-breach.md
---

### 1. Does Layer 1 alone close the demonstrated reach paths?
**Yes, but strictly for unprivileged execution.**
Dropping the `127.0.0.1:14011` publish cleanly severs the host loopback vector, and removing `websurfinmurf` from the `docker` group drops ambient access to the Docker socket. The `pkill` is the correct way to flush existing session tokens.

**However, the `sudo` bypass is total.** You noted that `sudo` is out of scope for this pass, but you must operate with the understanding that retaining `sudo` means Layer 1 is a "gentleman's agreement" with the AI. If the agent can invoke `sudo` (e.g., passwordless `sudo`, or it knows the password), it can instantly recreate the exact same breach by running `sudo docker run --network mcp-ib-live-net ...` or `sudo nsenter -t <ibgateway_pid> -n curl`. Layer 1 stops accidental ambient reach, but provides **zero** boundary against an autonomous agent leveraging its existing `sudo` privileges.

### 2. Is rootless docker on the same host the right Layer 2?
**Yes, it is the correct near-term architectural move.**
Moving live workloads to `~administrator/.local/share/docker` establishes a strong Discretionary Access Control (DAC) boundary. It ensures that if the developer agent is later re-granted `docker` group access (e.g., for standard paper trading development), it does not implicitly regain access to the live gateway.

*Crucial Caveat:* Just like Layer 1, rootless docker is defeated by host `sudo`. If the AI uses `sudo su - administrator`, it owns the rootless daemon. Rootless docker protects the host from the container; it does *not* protect the container from host root. Given your constraints, it is still the right move, but do not mistake it for a boundary against a `sudo`-capable threat.

### 3. What's the right validation test plan?
To rigorously validate Layer 1, execute these steps as the `websurfinmurf` user/agent. You must test both the closure of the unprivileged paths and the reality of the escalated path:

1. **Verify Socket Denial:** `docker ps` — Must fail with "permission denied" on `/var/run/docker.sock`.
2. **Verify Loopback Denial:** `nc -vz 127.0.0.1 14011` — Must fail with "connection refused".
3. **The Proof-of-Concept Re-run:** Have `websurfinmurf` run the exact Python script/container spin-up from their original demo. It must fail.
4. **The Sudo Reality Check:** Have `websurfinmurf` run `sudo docker run --rm --network mcp-ib-live-net ...` with the Python payload. **It will succeed.** You must run this test so you have concrete proof of the risk you are accepting by leaving `sudo` intact for the dev identity.

### 4. Anything we're missing entirely?
Yes, you have a major lateral bypass in your network topology:

* **The `mcp-net` Pivot (CRITICAL):** You stated the live wrapper joins *both* `mcp-ib-live-net` and `mcp-net`. This bridges the networks. If `socat` or the wrapper application binds to `0.0.0.0:4003` internally, it will accept traffic from `mcp-net`. Any container the AI can control on `mcp-net` (e.g., a paper trading bot, a dev tool, or a compromised adjacent service) can simply connect to `<live-wrapper-alias>:4003` over `mcp-net` and place live orders. **Fix:** The live wrapper must *only* join `mcp-ib-live-net`, OR it must strictly bind its listening ports to the specific `mcp-ib-live-net` interface IP inside the container (not `0.0.0.0`).
* **VNC Port Exposure:** If the live gateway exposes VNC (default 5900) to `mcp-net`, the developer agent can pivot via VNC, open the TWS UI interactively, and place orders manually. VNC should be bound strictly to `127.0.0.1` inside an admin-only network, or disabled entirely for live.
* **Shared Host Mounts:** Ensure no host directories (like `./jts` or `./ibc`) are writable by `websurfinmurf`. If the dev agent can write to the config files mounted by the live container, it can inject malicious commands into the `ibc` startup scripts that will execute inside the live container upon its next restart.
