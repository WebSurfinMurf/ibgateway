---
source: claude
reviewed: 2026-06-03
context: rootless-wall-2026-06-03.md
---

I've grounded this in your actual files. Three facts I verified before reasoning:

- **Kernel is `6.17.0-20-generic` on a Noble (24.04) userland** — an HWE/mainline kernel, not the 6.8 GA kernel Docker's Noble rootless AppArmor handling was written against. Notable, returning to it below.
- **Your rootless `daemon.json` is exactly `{iptables:false, ip6tables:false, bridge:none}`** as documented — confirms the doc is faithful.
- **`DOCKERD_ROOTLESS_ROOTLESSKIT_DETACH_NETNS` is set nowhere.** I grepped every file under `~/.config/systemd/user/`. Your only drop-in is the `ExecStart=` override; there is no `Environment=` line touching it. So detach-netns is at its **default = on (detached)** on Docker 29.1.3. Your "we never confirmed the env var was set" — confirmed: it is definitively *not* set.

I cannot run `docker`/`sudo` on the host from this sandbox (I'm an unprivileged uid in a container that only mounts `/workspace/administrator`), so the discriminating commands below are for you to run. They're all read-only — zero breach cost.

---

## Bottom line up front

You are debugging a boundary that **does not bind against your actual threat.** Rootless-under-administrator only contains the agent *after* the agent has lost the rootful docker socket — and once it's lost the socket, plain Phase A already contains it and rootless is redundant. Worse, the AppArmor changes you made to chase rootless have **globally weakened userns restriction for all 60+ containers on the host, including the agent's.** Stop fighting rootless. Close the real breach with the certain control you already validated, set the IBKR-side cap, and revert the host-wide AppArmor weakening. Diagnosis follows so you can document *why* it walled, then move on.

---

## Q1 — What's actually blocking the bridge driver and the AppArmor check

The whole puzzle is one contradiction: **manual `unshare -U -r -n` and manual `rootlesskit --net=slirp4netns` succeed at the exact operations (`ip link add … type bridge`, `ip6tables -t nat -N`, sysctl writes) that `dockerd-rootless` fails with EPERM/EACCES.** Same host, same uid, same userns mechanism, `CapEff: 000001ffffffffff` in both. Capability bits are NOT the difference. So the difference is *something that mediates the operation independently of kernel credentials*, and that something differs between an interactive process and the daemon.

There are exactly two candidates that fit that signature. They're discriminable in one command.

### Leading hypothesis: dockerd-rootless is AppArmor-confined; the manual reproductions are not

AppArmor **capability mediation is orthogonal to kernel credentials.** A process confined by a profile containing `audit deny capability` (your doc confirms the parent `unprivileged_userns` profile carries exactly this) gets **EPERM on every CAP_NET_ADMIN-gated syscall** — `RTM_NEWLINK`/MTU set, bridge create — *regardless* of a full `CapEff`. And `open(/proc/sys/net/ipv6/conf/docker0/accept_ra)` returning **EACCES** is AppArmor `file` mediation (or a netns/procfs ownership mismatch) on that path. The errors line up one-for-one with capability+file mediation.

Why manual works and the daemon doesn't — **the profile attaches by transition at exec time, not by uid:**
- Your interactive `unshare`/`rootlesskit` tests run from administrator's **unconfined login shell** and stay unconfined → no capability mediation → bridge create works. This is why your "manual works!" test is misleading: it proves the *namespace* is fine while testing a process in a *different confinement context* than the daemon.
- `flags=(unconfined)` on `/etc/apparmor.d/unprivileged_userns` only changes behavior for processes that **transition into that profile name after the reload.** Two ways it silently doesn't reach the daemon: (a) `apparmor_parser -r` does **not** re-transition an already-running process — the live `dockerd`/`rootlesskit` keep whatever profile they got at exec; you must fully stop the daemon *and* its rootlesskit parent and re-launch (and arguably re-login the user session). (b) If dockerd-rootless transitions into a *different* profile name (a `rootlesskit`/`dockerd` profile, or `docker-default`), unconfining `unprivileged_userns` is irrelevant.

Note your sysctl `apparmor_restrict_unprivileged_userns=0` does **not** help here. That sysctl gates userns *creation* — and your userns clearly gets created (the daemon starts, manual unshare works). It does nothing about *capability mediation inside* a userns owned by a confined process. Two different AppArmor mechanisms; you fixed the one that wasn't the wall.

### Failure 2 (the AppArmor profile check on `docker run`) is the same root cause

`Could not check if docker-default AppArmor profile was loaded: open /sys/kernel/security/apparmor/profiles: permission denied`. A *clean* rootless daemon's `apparmor.HostSupports()` returns false because securityfs isn't visible in the rootless mount namespace, so dockerd **skips** the profile check entirely. Here securityfs is partially visible (host `/sys/kernel/security` leaking into the rootless mount ns), so `HostSupports()` returns true but the unprivileged user can't read `profiles` → EACCES → the check errors instead of being skipped. Same AppArmor-awareness leak as Failure 1's family, downstream of it.

### Alternative hypothesis: RootlessKit detach-netns (if AppArmor is exonerated)

Docker 29.1.3 defaults to detached netns (confirmed unset → default-on in your config). In detached mode the slirp4netns netns is split from dockerd's, and the default-bridge sysctl/netlink config can hit a netns/procfs ownership mismatch that yields EPERM/EACCES specifically on `docker0`. Your manual `rootlesskit --net=slirp4netns sh -c` test runs **single-netns** (not detached) — which is *another* reason it succeeds where the daemon fails. This is a genuinely plausible second cause and is exactly why your "not yet tried" list named the env var.

### The one decisive, read-only discriminator — run this first

```bash
DH=$(pgrep -x dockerd)                       # the rootless dockerd
sudo cat /proc/$DH/attr/current              # "unconfined" ⇒ AppArmor exonerated
ps -Z -p $DH
# the smoking gun — AppArmor logs the exact op + profile + capability it denied:
sudo dmesg -T | grep -iE 'apparmor.*denied' | tail -40
sudo journalctl -k -g 'apparmor=.?DENIED' --since '-2h' --no-pager | tail -40
```

- **DENIED lines naming `operation="capable" capname="net_admin" profile="…"`** → AppArmor confirmed. The profile name in that line is the one to unconfine/restart, not necessarily `unprivileged_userns`.
- **No denials AND `attr/current` = `unconfined`** → AppArmor is out; it's detach-netns. Then, and only then:
  ```bash
  cat > ~/.config/systemd/user/docker.service.d/env.conf <<'EOF'
  [Service]
  Environment=DOCKERD_ROOTLESS_ROOTLESSKIT_DETACH_NETNS=0
  EOF
  systemctl --user daemon-reload && systemctl --user restart docker
  systemctl --user show docker -p Environment   # PROVE it took — your last attempt didn't
  ```
  then drop `"bridge":"none"` and `docker network create test`.

You've been testing the credential path (which is fine) instead of the *discriminating* path (why the daemon's context differs). `dmesg | grep apparmor` would have ended this on day one.

---

## Q2 — Keep fighting rootless on this host? No.

Not because it can't be made to work — with the dmesg output it probably can in 1–2 steps. **Because making it work doesn't achieve your goal, and the attempt is actively costing you.**

The goal (doc line 12): the agent "cannot reach the live network *even with full docker daemon control*." But **full rootful-daemon control = host root.** A container mounting `/var/run/docker.sock` can `docker run --privileged -v /:/host` → root on the host. And **host root owns administrator's rootless daemon**: `/run/user/2000/docker.sock` is just a file root reads; `nsenter -t <live-pid> -n` walks straight into the live container's netns. Rootless isolates the rootless daemon's containers **from other unprivileged users — not from host root.** So:

> If the agent keeps the rootful socket, rootless-on-this-host is theater.
> If the agent loses the rootful socket (Phase A), the agent is already contained and rootless is redundant defense-in-depth.

Either way rootless is not the load-bearing boundary. And the cost is real and ongoing: the live stack is on the rootful daemon **right now** with the breach open, every debugging minute is real-money exposure (your words), *and* your `apparmor_restrict_unprivileged_userns=0` + `flags=(unconfined)` edits **weakened userns restriction for the entire host** — all 60+ containers including the agent — to benefit one service. That's a net security regression in service of a boundary that doesn't bind.

**Most-decisive next thing:** not a fix — a measurement. Run the `dmesg | grep apparmor` block above, capture the result into the postmortem so the wall is documented, then stop.

---

## Q3 — Right architecture

**Recommended (the correct end-state, option D): remove the agent's path to host root, then bound the blast radius IBKR-side. Drop rootless entirely.**

1. **Close the host-root path (this is the actual boundary, today):** agent runs as a dedicated uid (`websurfinmurf-agent`), **not in `docker`, not in `sudo`, no `docker.sock` mount on any container it can exec into.** This is Phase A3/A4 + the C2 identity split that "silently disappeared" per your prior synthesis. Once the agent cannot reach host root, the *entire host-root trust domain is trustworthy again* — which is what makes rootless redundant rather than necessary.
2. **IBKR-side limits on `U15907310` — promote to FIRST, today, not "this week":** trusted-IP allowlist (this host's egress IP only), sub-account with hard notional/position/daily-loss caps, daily order-count cap. This is the **only** control that survives full host compromise, and it's IBKR-portal config — zero infra hours, no competition for the same time. It being in "Phase C" is a mis-tiering: it's your real-money insurance and should bound the blast radius *before* you touch infra.
3. **If you want an infra boundary that survives host root, it must be a *separate trust domain*, not a same-host primitive.** A separate physical box or a cloud VM. **Option B (local VM) does not qualify** — host root owns local VMs too (`virsh`, the qcow2 on disk, ptrace of the qemu process, the serial console). B buys operational tidiness, not a security boundary against your stated threat.

Explicitly on your options:
- **(A) keep fighting rootless** — No. Success ≠ goal.
- **(B) local VM** — No for security (host root owns it). Don't spend the 1–2 hours believing it isolates from the agent.
- **(C) "accept partial Phase A"** — Your doc labels this "the shortcut" and the anti-pattern. **That label is the error.** Phase A (take away the socket) + identity split + IBKR caps is not a shortcut — it's the architecturally correct *core*. Rootless was the residual nice-to-have; the socket removal is the load-bearing fix. Reframe, don't reject.
- **(D)** — the above.

This is fully consistent with your "do it right once" principle: the right thing is removing host-root reach + IBKR limits (+ separate host if you want infra isolation). Rootless-on-same-host is the tech-debt detour here — high effort toward a boundary host root walks through.

---

## Q4 — What I'd do in the next 10 minutes (operator hat)

The live breach is open *now*; the rootless project has been prolonging it. Spend the 10 minutes closing the certain thing, not the uncertain one:

1. **Measure the actual current exposure (2 min):**
   ```bash
   getent group docker
   docker ps --format '{{.Names}} {{.Mounts}}' | grep docker.sock
   docker inspect mcp-ib-live --format '{{json .NetworkSettings.Networks}}'   # confirm off mcp-net/traefik-net
   ```
   Every name in line 2 is host-root-equivalent. Any that the agent can exec into = the live breach, right now.
2. **Set the IBKR daily order-count + notional cap and trusted-IP allowlist on `U15907310` (5 min, IBKR portal).** This shrinks the blast radius to near-zero *regardless* of any infra state, and it survives host root. Do this first if markets being open worries you at all.
3. **Cut the agent's socket path (3 min):** remove the agent uid from `docker`, recreate the socket-mounting agent container(s) without the mount, `pkill -KILL -u <agent-uid>`. That's Phase A3/A4 — already validated.

Then, *separately and at leisure with autotrade off*, run the `dmesg | grep apparmor` discriminator to document the rootless wall, and **revert the host-wide AppArmor weakening** (`unprivileged_userns.bak` → restore; `apparmor_restrict_unprivileged_userns=1`) since you're no longer pursuing rootless and that change weakened all 60+ containers.

---

## Blind spots a same-context reviewer would miss

1. **The host-root blind spot (the big one).** Everyone is heads-down on "make rootless work" and nobody re-checked whether *working rootless* meets the goal. It doesn't, while the agent holds the rootful socket — host root reads `/run/user/2000/docker.sock` and `nsenter`s into live. The boundary doesn't bind. This invalidates A *and* B as security measures.
2. **The AppArmor edits regressed the whole host.** `apparmor_restrict_unprivileged_userns=0` + `flags=(unconfined)` are *global*. You widened unprivileged-userns attack surface for all 60+ containers — including the very agent you're defending against — to chase isolation for one. Net-negative; revert it.
3. **The breach window is self-inflicted by sequencing.** "Every minute of debugging is exposure" is true *because* the certain fix (Phase A, minutes) was deferred to chase the uncertain one (rootless, days). The correct order is the inverse — and it's the inverse of your own "do it right once."
4. **IBKR controls are mis-tiered.** The only control that survives host root sits in "this week / Phase C." It's portal config with zero infra cost. It should be first.
5. **Confirmation-biased testing.** The team over-verified the parts that work (`CapEff`, manual unshare — both unconfined contexts) and never ran the one command that discriminates (`dmesg | grep apparmor`, `cat /proc/$DH/attr/current`). The manual test proves the namespace is capable; it says nothing about the daemon's confinement.
6. **Kernel 6.17 on Noble.** Docker's Noble rootless AppArmor profiles target the 6.8 GA kernel. On a 6.17 HWE/mainline kernel the profile-name matching and `userns` semantics may have drifted — another reason the ROI on finishing rootless here is poor even if you could.
7. **Secrets residual is unchanged regardless.** Live `TWS_PASSWORD` lives in the container env, readable by host root via `docker inspect` / `/proc/<pid>/environ`. This independently confirms: host root = game over → the boundary must be host-root-removal + IBKR limits + (optionally) a separate host. Same conclusion from a second direction.
