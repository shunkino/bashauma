# Hockney History

## Project context

- Project: herdr extension
- Preferred implementation: shell-first, lightweight scripting
- Quality focus: normal review, linting, and test discipline
- Publishing goal: clean repository release with verifiable quality checks
- User: Shun Kinoshita

## Initial orientation

- Verify behavior with small, focused tests.
- Keep lint and review expectations practical and maintainable.
- Ensure repo quality matches the publication target.

## Summary: proactive v1 test harness (2026-08-18T22:37:23+09:00)

- Built a dependency-free shell test harness under `tests/` (`run_tests.sh`
  runner, `tests/lib/harness.sh` assertions/setup-teardown/entrypoint
  helpers, `tests/fixtures/bin/herdr` fake CLI stub) proactively, ahead of
  Fenster's implementation. 10 case files, one per PRD requirement group.
- Drove tests through indirection env vars `BASHAUMA_SCHEDULER_CMD`/
  `BASHAUMA_NEXT_CMD` since Keaton's interface wasn't decided yet; updated
  afterward to match Keaton's locked file names and confirmed
  `HERDR_PLUGIN_CONTEXT_JSON` contract.
- Verified against v0.1 `on_status_changed.sh`: 5/10 pass, 5/10 fail with
  informative per-assertion messages, as expected pre-implementation.
  Confirmed bash-3.2-safe (no bash-4-only constructs).
- Did not touch `on_status_changed.sh`/`winner_screen.sh`/
  `herdr-plugin.toml`/`README.md`.

📌 Proactive: written from the PRD while implementation was in progress.

## Summary: review of Fenster's landed v1 implementation — REJECTED

- Reviewed `lib/state.sh`, `lib/config.sh`, `lib/scheduler.sh`,
  `on_status_changed.sh`, `next.sh`, `herdr-plugin.toml` v1.0.0.
- Confirmed clean: single `agent focus` call site; no `notification show`;
  §10 no-partial-writes; `mode=off` semantics; numeric (not lexicographic)
  `state_change_seq` sort; bottom-anchoring ERE correct; aging-clock-reset
  bounded, no §9 starvation violation (undocumented "3" threshold noted as
  minor).
- Found two real, reproducible BLOCKERS, each pinned with a new regression
  test (`tests/cases/regression_lock_scope.sh`,
  `tests/cases/regression_fractional_aging_seconds.sh`):
  1. State lock held across external `herdr agent list`/`pane read` calls,
     risking a double-writer race with the 30s stale-lock reclaim.
  2. `aging_threshold_ms` bash-integer arithmetic crashes on a fractional
     `aging_seconds` (e.g. `0.5`) under `set -euo pipefail`, silently
     dropping the whole yield.
- Minor/nits (not blocking, no test added): missing final sort tiebreaker;
  `mode=off` wastes one debounce cycle; transient `agent get` failure
  drops a dispatch with no retry; ANSI-escape robustness only tested in
  one shape; `_now_ms()` BSD `%N` fallback untestable in this sandbox.
- Suite: 12 case files (10 original + 2 new), originals green, new ones
  fail as designed. **Verdict: REJECTED.** Fenster locked out per
  reviewer-protocol; named **Keaton** as fix agent.

## Summary: re-review of Keaton's v1 lock-scope fix — APPROVED WITH NITS

- Independently re-ran suite: 12/12. Traced the new 3-phase `schedule()`
  lock design line by line — confirmed Phase 3 always re-reads state
  fresh under the lock (`prelock_state` never referenced there), so the
  lost-update race does not occur; a genuine fix, not a relocation.
- Found the "rare in-lock fallback" is real but slightly broader than
  described (gated on the whole Phase-2 confirm loop, not an instant) —
  MINOR, not blocking.
- Verified `_config_to_int` truncation against requested edge cases;
  found it silently swallows a few invalid forms (no stderr signal at the
  time) — MINOR nit, later addressed by issue #2.
- Re-verified §9 single-call-site invariant, §6.4 now-total sort order
  (pane_id tiebreaker), and full regression sweep (§5/§10/`mode=off`/
  §6.2/Rai's option-injection hardening) — all clean. Accepted Keaton's
  three deferrals as non-blocking for v1.
- **Verdict: APPROVED WITH NITS.** Cleared for release.

📌 Team update (2026-08-18T22:37:23+09:00): rejected Fenster's v1
(lock-scope + fractional-aging_seconds blockers), then approved-with-nits
Keaton's fix after independent re-verification of both blocker fixes —
decided by Hockney.

## Summary: review of Fenster's v1.1 follow-up, issues #1/#2 — REJECTED (issue #1)

- Independently re-ran 12/12 baseline; added 3 regression tests:
  `regression_close_reopen_pruning.sh` (passes — confirms unbounded-growth
  half fixed), `regression_config_warning.sh` (passes, 6/6 — confirms
  issue #2's exact warning text across rejection variants incl. `1e3`
  round-tripping through jq, plus no-warning-on-valid-truncation), and
  `regression_id_recycle_suppression.sh` (fails by design — my own
  addition, targeting whether Fenster's fix closes the herdr-restart/
  ID-reuse scenario he named "the more serious half").
- Traced that scenario concretely: pruning only removes an entry for a
  pane_id *observed absent* from `agent list`. A recycled pane_id (after
  a herdr server restart resets a workspace's ID counter) is by
  construction never observed absent before it reappears, so the very
  first post-restart `schedule()` call already sees it as live and the
  prune predicate never removes the stale entry. Fenster's code comment
  claiming this closed the gap "for free" was incorrect — proved with
  the failing test: a genuinely blocked, P0-confirmable pane inheriting
  stale suppression loses to a lower-priority idle candidate instead of
  winning P0.
- Confirmed the unbounded-growth half genuinely is fixed; confirmed
  pruning-on-close isn't itself exploitable mid-session (pane IDs are
  monotonic per-workspace within one herdr session — only a full server
  restart recycles them, which a single agent can't trigger); confirmed
  §6.4's epoch-survival promise still holds; verified all three
  `_config_to_int` call sites and the bash-3.2/`set -u`-safe optional-arg
  pattern; judged unrated-limited stderr warning noise acceptable for v1.
- **Verdict: REJECTED** (issue #1 only; issue #2 approved on its own
  merits). Fenster locked out of `lib/scheduler.sh`'s close-pruning logic
  this cycle. Named **Keaton** as fix agent.

## Summary: re-review of Keaton's `state_change_seq` lineage fix — APPROVED WITH NITS

- Re-ran suite independently: 15/15 → 16/16 after adding
  `regression_suppression_survives_lineage_check.sh`, confirming the
  lineage check (`_lineage_trusted`/`_forget_stale_pane`, keyed on a
  `demotion_seq` baseline vs. observed `state_change_seq`) does not
  silently disable the suppression feature it protects — the single
  biggest risk in this design.
- Independently investigated `state_change_seq` against the live herdr
  binary (read-only, no server restart): values tightly clustered
  (287–314) across 6 agents in 4 workspaces vs. clearly-per-pane
  `revision` (30–60) — strong evidence it's a global, not per-pane,
  counter (Keaton's writeup had implied per-pane). Judged this
  strengthens rather than undermines the fix's likely correctness (a
  full-server-restart reset of one shared counter is architecturally
  safer to assume than N independent per-pane resets); disclosed the
  residual restart-reset uncertainty as unverified but non-blocking,
  since the fix cannot regress below the pre-fix bug even if wrong.
- Verified upgrade safety directly: fed a pre-1.0.1-shaped `state.json`
  (no `demotion_seq` key) through `_forget_stale_pane`'s jq pipeline — no
  crash, correct output (jq's null-safe indexing, not `set -u`-sensitive).
- Re-traced §9 single-call-site invariant, §6.4 determinism/lock
  discipline (mutation runs entirely inside the existing Phase-3 lock,
  deterministic), and the full regression sweep (§5/§10/`mode=off`/§6.2/
  Fenster's issue #2 work) — all clean. Confirmed `bash -n`/`shellcheck -x`
  clean and `awk` numeric comparisons portable (BSD/GNU).
- Non-blocking nit: `CHANGELOG.md`'s 1.0.1 entry was stale, still
  describing the rejected presence-based fix's caveat rather than the
  shipped lineage mechanism — flagged for Verbal/Keaton (since corrected
  by Verbal).
- **Verdict: APPROVED WITH NITS.** Both prior blockers genuinely closed;
  the residual restart-reset uncertainty is well-evidenced, honestly
  disclosed, and fails safe. Release proceeded at 1.0.1.
