# Verbal History

## Project context

- Project: herdr extension
- Delivery style: lightweight and shell-first
- Publishing goal: a clean, contributor-friendly public repository
- Quality bar: standard review and validation, with clear docs
- User: Shun Kinoshita

## Core working pattern

- Keep docs aligned to the actual repo workflow and shipped code.
- Prefer concise, accurate instructions over process-heavy prose.
- Correct specs when the live CLI differs from prior assumptions.

## Key outcomes

- Rewrote README and CHANGELOG for v1 and synced them after follow-up fixes.
- Corrected the prd.md keybinding claims to match the real user-side binding workflow.
- Documented v1.1 explain, workspace locality, predictability, and explain.json accurately.
- Kept the public docs aligned with the shipped version numbers and diagnostic behavior.
- 2026-08-22T10:14:20+09:00: Documented issue #4 keyword transition hold for release 1.2.0, including opt-in config, hold log retrieval via `herdr plugin log list --plugin bashauma`, and `next` bypass semantics.

📌 Team update (2026-08-22T10:14:20+09:00): Issue #4 keyword transition hold shipped as bashauma 1.2.0 with dispatch-only holds, `next` as escape hatch, documented config/logging, and 21/21 tests passing. Issue #3 demotion-count decay remains blocked until real A-0 logs show same-lineage suppression harm; #3 should reuse the lineage-check skeleton extracted for #4 — decided by Keaton, Fenster, Hockney, and Verbal.
