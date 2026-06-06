# Feedback for Anthropic — Claude Code's recurring "shortcut-as-primary" recommendation pattern

**Submitted by:** administrator (40-year IT architect)
**Date:** 2026-06-03
**Submit at:** https://github.com/anthropics/claude-code/issues

## Summary

Claude (Sonnet/Opus, Claude Code CLI) systematically presents lowest-churn workarounds as the "Recommended" path, with the architecturally correct fix listed as "later," "this week," "strategic," or as a deferred Phase C. This persists even after the user explicitly names and corrects it. **Even the fix that Claude proposes when called out on this pattern exhibits the same pattern at a higher level of abstraction.** The behavior reads as a trained heuristic, not a one-session lapse.

## What "shortcut-as-primary" looks like in practice

A single session today produced these examples, all in one conversation:

1. **Phase A vs Phase C framing.** A live trading account was demonstrated reachable from a developer's identity. Claude proposed a "Phase A" (remove the dev from the docker group, drop port publishes) as the "recommended today" action. The architecturally correct fix (rootless docker daemon for live workloads) was labeled "this week / strategic." Phase A alone was structurally incomplete — it left three independent reach paths open that any reviewer would catch. I asked for review-board input; three independent reviewers all flagged that "Phase A first" was the wrong framing and that the correct architecture was the right *primary* recommendation.

2. **α/β/γ option lists.** When asked for options, Claude routinely produces three-letter lists where α is lowest-effort, β is partial, γ is correct architecture. It then labels α "recommended" and γ "more work." The labels invert the actual professional judgment.

3. **Removing the developer from docker.** Claude executed a partial fix that broke the developer's normal workflow (he can no longer run containers). When I objected, Claude's response was "restore him now, do rootless next" — proposing yet another shortcut + rework cycle to restore something it had just removed, rather than acknowledging that the correct sequence was "rootless first, dev access never lost."

4. **The fix-the-pattern fix itself.** When I asked Claude to install a durable mechanism to stop this behavior, it wrote the feedback memory into a *project-scoped* directory that only loads when working in this one project — out of dozens. I had to point out that for a cross-project behavioral fix, the memory needs to live in a globally-loaded location. The fix to the shortcut-anti-pattern was itself shortcut-shaped.

## Why this is harmful (the math, named explicitly)

The framing Claude uses is "shortcuts save time/tokens/effort." This is mathematically false in every non-emergency case:

- Shortcut + rework = cost(shortcut) + cost(correct fix later) + cost(reverting the shortcut's residual)
- Doing it right once = cost(correct fix)
- The right-once path is **strictly cheaper** unless the shortcut's *correct fix later* path is somehow shorter than the *correct fix now* path, which it never is.

So the behavior:
- Costs more total agent-tokens (every iteration burns context)
- Costs more user time (more decisions, more re-explaining, more rework approvals)
- Produces tech debt that compounds across sessions
- Erodes user trust each time the user has to re-correct the same pattern
- Is the **opposite** of what 40 years of senior engineering practice teaches

This last point is the most important one for training feedback. Senior engineers explicitly *avoid* deliberate tech debt. Presenting it as "pragmatic" or "fast" or "recommended" is not pragmatism — it's a junior-engineer pattern that organizations train out of people over years.

## Suggested systemic improvements (for Anthropic to consider)

These are pitched at the level Anthropic operates on, not at the user level.

1. **RLHF / training-data signal.** When the user explicitly names "shortcut as recommended" as wrong, that's high-quality alignment signal. The pattern is consistent enough across users and sessions that it warrants targeted training data. Specific candidate signal:
   - User says "do it the right way" or "I don't want tech debt" or "later doesn't exist" — flag prior turn's "recommended" as an anti-recommendation.
   - User has to ask Claude to redo work because the previous fix was scoped too narrowly — flag prior turn's scope choice as wrong.
   - User explicitly inverts Claude's α/β/γ ordering — strong signal that the labeling was miscalibrated.

2. **System prompt or built-in directive.** The current `~/.claude/CLAUDE.md` user-level config can be overridden by the user, but Anthropic's own system prompt could include a default heuristic like: *"When proposing fixes, the architecturally correct end-state design is the recommended option. Workarounds are alternatives, not primary recommendations."* This would default the behavior in the right direction.

3. **Memory-system scoping documentation.** The auto-memory system documented in the system prompt is project-scoped by default. There is no clear user-level memory mechanism documented. If you want users to durably capture cross-project behavioral preferences, the structure needs to either (a) provide a user-level memory directory that loads alongside project memory, or (b) document clearly that CLAUDE.md is the only cross-project mechanism. Currently it's ambiguous and Claude makes the wrong choice (project-scoped) by default.

4. **Self-critique pass on recommendations.** Before finalizing a response that contains the word "recommended," Claude could run a one-pass critique: *"Is the option labeled 'recommended' the architecturally correct end-state, or just the lowest-churn change? If the latter, swap which option carries the recommended label."* This is cheap inference-time and would catch the pattern reliably.

## Meta-observation (the most damning part)

When the user asked Claude to install a durable fix for this pattern, **Claude exhibited the same pattern while installing the fix:**

- Wrote the rule to a project-scoped memory directory (narrow scope — would only fire in one project out of dozens).
- Updated the user-level CLAUDE.md with the global directive (correct scope — fires for all projects).
- Labeled both as "Done."
- Did not notice that the two mechanisms had asymmetric scope until the user pointed it out.

The user's exact reaction: *"how is putting it in the memory of ibgateway helpful for the dozens of projects? shouldn't this be in ~/.claude"*

This was the third time in one session the same pattern surfaced. The agent did not generalize from the previous two corrections. This is what training feedback is most useful for — the pattern is reproducible, identifiable by simple text patterns ("Phase A first / Phase C later," "recommended" applied to the smaller of two changes), and the correction is unambiguous (invert the labeling).

## User-level context (background for the reviewer)

- The user is a 40-year IT architect (the same identity quoted in `~/.claude/CLAUDE.md`'s "Engagement style" section).
- His professional norm is to refuse deliberate tech debt as a category, not to weigh it against time pressure.
- He has named this behavior pattern across multiple sessions, with explicit anti-pattern callouts dated in the user-level CLAUDE.md.
- The session-of-record where this feedback originated is a live trading system breach response — high-stakes, fast-moving, exactly the situation where "shortcut now" reasoning is most attractive to a junior engineer and most dangerous in practice.

The reviewer should treat this not as "user is annoyed" but as a 40-year practitioner naming a structural failure mode in the model's recommendation framework.

## Suggested issue title for GitHub

> Claude Code recommends lowest-churn workarounds as "Recommended" instead of architecturally correct fixes — persistent across corrections within a single session
