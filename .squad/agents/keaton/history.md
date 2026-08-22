# Keaton History

## Project context

- Project: herdr extension
- Primary language: shell-first scripting
- Operating model: lightweight, portable automation
- Quality bar: normal testing, review, linting, and publish-readiness checks
- User: Shun Kinoshita

## Core working pattern

- Verify live CLI/schema details before changing specs or architecture.
- Prefer small, reviewable scheduler steps with explicit evidence gates.
- Keep design docs, decision logs, and shipped code aligned.

## Key outcomes

- Designed v1 after verifying the real herdr manifest/API surface and confirming there is no plugin `[[keybindings]]` table.
- Fixed review blockers: lock scope, numeric coercion, permissions hardening, and `mode=off` timing.
- Shipped the issue #1 lineage fix with `state_change_seq` / `demotion_seq` instead of presence-only pruning.
- Designed the v1.1 A/B/C proposal, then revised it after the Devil's Advocate brief to: `explain` first, then A-0 logging, then B-lite, with C hardened and A-full/B-full gated behind evidence.
- Kept the design record in sync with the persisted v1.1 scheduling document and decision inbox.

## 2026-08-22T10:14:20+09:00 — triage #3 vs #4

Confirmed from `lib/scheduler.sh` that A-0 suppression logging shipped in fbc9591: threshold-crossing and suppressed-close-prune events go to stderr. Checked live `herdr plugin log list --plugin bashauma`; it returned no log entries, so #3 remains evidence-starved. Decision: build #4 next, keep #3 deferred until real suppression logs show at least one persistent same-lineage suppressed pane that later appears genuinely blocked or otherwise harmful.

📌 Team update (2026-08-22T10:14:20+09:00): Issue #4 keyword transition hold shipped as bashauma 1.2.0 with dispatch-only holds, `next` as escape hatch, documented config/logging, and 21/21 tests passing. Issue #3 demotion-count decay remains blocked until real A-0 logs show same-lineage suppression harm; #3 should reuse the lineage-check skeleton extracted for #4 — decided by Keaton, Fenster, Hockney, and Verbal.
