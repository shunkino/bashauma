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

## Session: proactive v1 test harness (2026-08-18T22:37:23+09:00)

- Task: build a dependency-free shell test harness under `tests/` for
  prd.md's v1 scheduler, proactively, while Fenster's implementation was
  still in progress.
- Delivered:
  - `tests/run_tests.sh` — POSIX `sh` runner: discovers `tests/cases/*.sh`,
    supports name-filter args, colored pass/fail per case + summary,
    non-zero exit on any failure. (Fixed a `set -e` + command-substitution
    footgun where a failing case's exit code aborted the runner before it
    could report — assignment now goes through an `if/else`.)
  - `tests/lib/harness.sh` — `assert_eq`/`assert_contains`/
    `assert_not_contains`/`assert_exit_code`, per-test `setup_test`/
    `teardown_test` (fresh `HERDR_PLUGIN_STATE_DIR` + herdr-stub sandbox),
    `invoke_status_changed`/`invoke_next` entrypoint helpers, and
    focus/winner-screen assertion helpers backed by the stub's log files.
  - `tests/fixtures/bin/herdr` — fake `herdr` CLI stubbing `agent list`,
    `agent get` (with agent_list fallback), `agent focus`, `pane read`,
    `pane list`, `plugin pane open`; logs every invocation.
  - 10 case files, one per PRD requirement group: §6.1 yield points, §6.2
    priority classes + bottom-anchoring, §6.3 epochs, §6.4 affinity/aging/
    FIFO/false-claim, §6.5 (the §9 hard invariant), §6.6 flicker, §6.8
    config, §10 edge cases, and a static non-goal guard (no `notification
    show`, no stray `agent focus`).
  - `tests/README.md` documenting how to run/add tests and the entrypoint
    indirection contract.
- Entrypoint indirection: since Keaton's interface wasn't decided yet when
  writing started, drove everything through `BASHAUMA_SCHEDULER_CMD`
  (default `on_status_changed.sh`) and `BASHAUMA_NEXT_CMD` (default
  `next.sh`), documented at the top of `tests/lib/harness.sh`. Keaton's
  concurrent session independently verified the real herdr API and
  **locked these exact file names** as authoritative in
  `.squad/decisions/inbox/keaton-v1-implementation-plan.md` — updated the
  harness afterward to also pass the confirmed `HERDR_PLUGIN_CONTEXT_JSON`
  departure-pane context (focused_pane_id/workspace_id/tab_id) to both
  entrypoints, replacing what had been a flagged assumption.
  `BASHAUMA_AGING_SECONDS`/`BASHAUMA_MODE`/`BASHAUMA_PARKED_PANES`/
  `BASHAUMA_BLOCKED_CONFIRM` remain flagged assumptions pending Fenster's
  actual config-loading implementation.
- Verified mechanically: ran the full suite against the current (v0.1)
  `on_status_changed.sh` — 5/10 cases pass (things v0.1 happens to still do
  right, e.g. simple dispatch-moves-focus and no `notification show`), 5/10
  fail with specific, per-assertion messages (missing P0/priority handling,
  no epoch/affinity/aging, no `next.sh`, no `mode`/`parked_panes` support)
  — exactly the informative-failure state expected pre-implementation.
  Confirmed no bash-4-only constructs (`mapfile`, etc.) so the suite runs
  under macOS's stock bash 3.2.
- Did not modify `on_status_changed.sh`, `winner_screen.sh`,
  `herdr-plugin.toml`, or `README.md` — those remain Fenster's/Verbal's
  files.
- Wrote `.squad/decisions/inbox/hockney-test-harness.md` for the team.

📌 Proactive: written from the PRD while the implementation was in
progress; may need adjustment once Fenster's interface is final.

## Session: review pass on Fenster's landed v1 implementation

- Ran a critical review of `lib/state.sh`, `lib/config.sh`,
  `lib/scheduler.sh`, `on_status_changed.sh` (rewrite), `next.sh` (new),
  `herdr-plugin.toml` (v1.0.0) — deliberately hunting for defects my own
  10/10-green suite would not catch.
- Confirmed structurally: `agent focus` reachable from exactly one call
  site (`lib/scheduler.sh`'s `schedule()`), only via the dispatch yield
  and `next` yield points; `herdr notification show` appears nowhere;
  `winner_screen.sh` and README.md's non-goals section are clean; §10
  `agent list` failure leaves state untouched with no partial writes;
  `mode=off` semantics correctly disable only the dispatch path per
  §6.8/README; jq sort uses `--argjson` (numeric, not lexicographic)
  for `state_change_seq`; bottom-anchoring ERE matches all §14 variants
  and same-line matching is the *correct* PRD reading, not a bug.
- Deep-traced the aging-clock-reset-on-demotion fix specifically looking
  for a §9 starvation violation — could not construct one; epoch-drain
  gating on "candidates empty" bounds resets to at most once per
  blocked-episode-per-epoch, with permanent suppression after 3
  cumulative demotions. Reporting as verified-correct with a MINOR nit
  (the "3" threshold is undocumented/unconfigurable, not PRD-specified).
- Found two real, reproducible defects and pinned each with a new
  regression test (added to `tests/`, which I own — did not touch
  `lib/`, entrypoints, or the manifest):
  - **BLOCKER**: the state lock (`state_acquire_lock`/`state_release_lock`
    in `lib/scheduler.sh`) is held across external `herdr agent list` and
    per-candidate `herdr pane read` calls, not just the state.json
    read-modify-write. This can race with the 30s stale-lock reclaim
    heuristic in `lib/state.sh`, risking a double-writer on state.json
    under real concurrent event-hook load. Proved deterministically (no
    timing race) via new `lock_held_during.log` instrumentation added to
    `tests/fixtures/bin/herdr` and a new
    `assert_no_calls_while_state_lock_held` helper in
    `tests/lib/harness.sh`; new case `tests/cases/regression_lock_scope.sh`
    fails as expected.
  - **BLOCKER**: `aging_threshold_ms=$((CONFIG_AGING_SECONDS * 1000))` in
    `lib/scheduler.sh` uses bash integer-only arithmetic, but the PRD
    config schema for `aging_seconds` has no integer-only constraint and
    README.md advertises `BASHAUMA_AGING_SECONDS` for ad hoc tuning. A
    fractional value (e.g. `0.5`) crashes the arithmetic at runtime and
    aborts the whole yield under `set -euo pipefail` — verified live by
    hand (exit 1, no focus move, lock still released correctly via the
    EXIT trap). New case
    `tests/cases/regression_fractional_aging_seconds.sh` fails as
    expected.
- Minor/nit findings also reported (not blocking, no test added): missing
  final tiebreaker in the sort key for a provably total order if
  `state_change_seq` ever ties; `mode=off` wastes one debounce cycle
  before checking config; a transient `agent get` failure during
  debounce re-verification silently drops a genuine dispatch with no
  retry; ANSI-escape robustness of the bottom-anchor regex tested only
  in one shape, not fully verified; `_now_ms()`'s BSD-date-without-`%N`
  fallback path structurally sound but untestable in this environment
  (this sandbox's `/bin/date` happens to support `%N`).
- Ran the full suite: 12 case files total, the original 10 still green
  and untouched, the 2 new regressions fail exactly as designed.
- Wrote `.squad/decisions/inbox/hockney-v1-review-rejected.md` with the
  full severity-ranked report.
- **Verdict: REJECTED.** Per reviewer-protocol strict lockout, Fenster
  (original author of all reviewed `lib/`/entrypoint files) may not
  self-revise. Naming **Keaton** (Lead) as the fix agent for this
  revision cycle.

## Session: re-review of Keaton's fix (revision cycle after REJECTED verdict)

- Independently re-ran the full suite (did not take the "12/12" claim on
  faith): confirmed 12/12, including both regression tests I added against
  the rejected v1. Confirmed `bash -n` and `shellcheck -x` clean myself.
- Traced the new 3-phase `schedule()` lock design in `lib/scheduler.sh`
  line by line, specifically hunting for the lost-update pattern the task
  called out: does Phase 3 re-read state under the lock and recompute, or
  write back values from the stale Phase-2 snapshot? Confirmed via grep
  that `prelock_state` (Phase 2's unlocked snapshot) is never referenced
  in Phase 3 — Phase 3 does its own fresh `state_load()` under the lock
  and every correctness-relevant check reads from that fresh state. The
  specific race asked about does not occur; this is a genuine fix, not
  just a relocation of the bug.
- Traced the "rare in-lock fallback" and found it's real but narrower
  than described: it's gated on a concurrent epoch-drain landing during
  this invocation's entire Phase 2 confirm loop (not just an instant),
  so in the worst case it can affect more than one candidate — reported
  as MINOR with a concrete recommendation (shrink the `prelock_state`
  capture window), not blocking, since correctness is preserved either
  way and it only degrades exposure, not output.
- Verified `_config_to_int`'s truncation rule against the specific edge
  cases requested (negatives, zero, empty, `1e3`, leading `+`,
  whitespace) by direct testing — deterministic and documented, but
  silently swallows a few of those (scientific notation, leading `+`,
  whitespace) with zero user-facing signal, unlike the existing
  jq-missing stderr-warning precedent elsewhere in the codebase — MINOR
  nit, not blocking.
- Re-verified §9: `agent focus` still reachable from exactly one call
  site, unchanged location, after re-tracing both entrypoints' full
  control flow post-refactor — holds.
- Re-verified §6.4 sort is now provably total with the `pane_id`
  tiebreaker (tested directly against a synthetic full-tie case).
- Regression swept §5 non-goals, §10 no-partial-writes (now strictly
  stronger — failure check happens before any lock is even attempted),
  `mode=off` semantics, and §6.2 bottom-anchoring (unchanged apart from
  Rai's `grep -Eqe` option-injection hardening, verified it doesn't
  change matching behavior for legitimate patterns) — all still clean.
- Judged all three of Keaton's deferrals (transient `agent get` retry,
  ANSI-escape edge case, `date %N` fallback) as acceptable to defer for
  v1 — none rise to blocking severity.
- Added no new regression tests this cycle — found no new defect
  requiring one; both prior regression tests now pass, confirming the
  fixes hold.
- Wrote `.squad/decisions/inbox/hockney-v1-rereview-approved.md` with
  the full findings.
- **Verdict: APPROVED WITH NITS.** Cleared for release from a QA
  standpoint.

📌 Team update (2026-08-18T22:37:23+09:00): rejected Fenster's v1 (lock-scope + fractional-aging_seconds blockers), then approved-with-nits Keaton's fix after independent re-verification of both blocker fixes — decided by Hockney.
