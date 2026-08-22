# Hockney History

## Project context

- Project: herdr extension / bashauma plugin.
- Hockney owns QA/review discipline: focused shell tests, invariant checks, and release gating.
- Prefer small, targeted regression cases and exact stderr/stdout assertions where stream identity matters.

## Condensed history (summarized 2026-08-22T10:14:20+09:00)

- Built the original dependency-free shell test harness (`tests/run_tests.sh`, `tests/lib/harness.sh`, fake `herdr`) from the PRD before v1 implementation; verified pre-implementation failures were informative and bash-3.2-safe.
- Rejected Fenster's first v1 implementation for two blockers: lock held across external herdr calls and fractional `aging_seconds` arithmetic crash. Added regression coverage, then approved Keaton's 3-phase lock/fractional fix with nits after suite re-verification.
- Reviewed issue #1/#2 follow-up: approved config warning behavior, rejected presence-based pane close/reopen pruning because recycled `pane_id` can inherit stale suppression after herdr restart. Added regression for ID-recycle suppression, then approved Keaton's `state_change_seq` lineage fix with nits and upgrade-safety checks.
- For v1.1, wrote proactive tests for `explain`, A-0 suppression logging, and B-lite workspace locality; found the major diagnostic-only bug where read-only `explain` emitted false A-0 threshold logs.
- Corrected the A-0 Scenario D test needle by separating harness stdout/stderr into `HARNESS_LAST_STDOUT`, `HARNESS_LAST_STDERR`, and compatible `HARNESS_LAST_OUTPUT`; verified the corrected test fails on the real pre-fix behavior and passes after `log_enabled` threading.
- Reviewed issue #4 keyword transition hold and approved with nits. Added `tests/cases/keyword_transition_hold_review.sh` with 40 assertions covering exact hold stderr, `next` bypass, inert defaults, bottom anchoring, fixed-string traps, ERE override, hold de-exemption, lineage survival, read-cost bounds, and determinism. Full suite: 21/21.

## Current team update

📌 Team update (2026-08-22T10:14:20+09:00): Issue #4 keyword transition hold shipped as bashauma 1.2.0 with dispatch-only holds, `next` as escape hatch, documented config/logging, and 21/21 tests passing. Issue #3 demotion-count decay remains blocked until real A-0 logs show same-lineage suppression harm; #3 should reuse the lineage-check skeleton extracted for #4 — decided by Keaton, Fenster, Hockney, and Verbal.

## Archive

- Full pre-summary detail preserved in `history-archive-2026-08-22T10-14-20+09-00.md`.
