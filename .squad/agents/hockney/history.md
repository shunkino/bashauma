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

## Session: review of Fenster's v1.1 follow-up (GitHub issues #1, #2)

- Read both issues (`gh issue view 1`, `gh issue view 2`) and the actual
  code (`lib/scheduler.sh`'s new close-pruning of
  `p0_suppressed_pane_ids`/`demotion_count`; `lib/config.sh`'s
  `_config_to_int` optional key-name + stderr warning).
- Independently re-ran the full suite (did not take "12/12" on faith):
  confirmed 12/12 baseline still green; re-ran `bash -n` and
  `shellcheck -x` myself, clean.
- Wrote the three regression tests Fenster explicitly asked for, plus one
  more of my own:
  - `regression_close_reopen_pruning.sh` (passes) — confirms the literal
    close-then-reopen prune scenario from issue #1.
  - `regression_config_warning.sh` (passes, 6/6) — confirms the exact
    warning message text for `"5m"`, `1e3` (round-trips through jq as
    `1E+3` — derived via jq in the test itself, not hand-guessed),
    `"+5"`, whitespace, and empty string, plus confirms no warning for
    valid fractional truncation (`2.7` → `2`).
  - `regression_id_recycle_suppression.sh` (fails by design) — my own
    addition, targeting the task's specific instruction to trace whether
    Fenster's fix actually closes the herdr-restart/ID-reuse scenario he
    named as "the more serious half."
- Traced that scenario concretely and found it is **not** fixed:
  pruning removes a suppression/demotion entry only when its pane_id is
  observed *absent* from the live `agent list`. A recycled pane_id (after
  a herdr server restart resets a workspace's ID counter) is, by
  construction, never observed absent before it reappears — the very
  first schedule() call post-restart already sees it as live, so the
  prune predicate treats it as "still valid" and never removes the stale
  entry. Fenster's code comment claiming this "closes that gap for free"
  is incorrect. Proved with the new failing test: a genuinely blocked,
  P0-confirmable pane that inherits a stale suppression record loses to
  a lower-priority idle candidate instead of winning P0, exactly the
  silent-permanent-denial failure the issue warned about.
- Confirmed the fix genuinely does solve the other half (unbounded
  growth for panes that close and stay closed) — kept that test as a
  passing regression.
- Checked whether pruning-on-close is itself exploitable by a flapping
  pane: confirmed not, since herdr allocates pane IDs from a monotonic
  per-workspace counter within a session (Fenster's own empirical
  finding) — a pane closing and reopening mid-session gets a genuinely
  new, higher-numbered ID, not its old suppressed one back. The only
  reuse vector is a full herdr server restart, which a single agent
  can't trigger on its own.
- Confirmed §6.4's "suppression survives an epoch" promise still holds
  for panes that stay open (only `epoch_fed_pane_ids`/
  `p0_demoted_pane_ids` reset at epoch drain, not
  `p0_suppressed_pane_ids`/`demotion_count`).
- Verified all three `_config_to_int` call sites pass the correct key
  name, and that the optional 3rd-arg pattern (`key="${3:-}"`) is safe
  under bash 3.2 + `set -u` (same pattern already used throughout
  `config_load`). Confirmed `lib/state.sh`'s `STATE_LOCK_STALE_SECONDS`
  coercion is a separate, independent inline `awk` guard unaffected by
  this signature change.
- Judged the warning-noise question (config_load runs on every hook
  invocation, so a persistent misconfiguration warns every time):
  acceptable for v1 — not proactively surfaced to the user, and
  persisting the warning for as long as the problem exists is arguably
  correct, not noise to suppress. Not blocking; flagged as a possible
  future nit only if `herdr plugin log list` volume becomes a complaint.
- Regression swept §9, §5, §10, `mode=off`, §6.2, §6.4, and the 3-phase
  lock discipline — all unaffected and still clean.
- Wrote
  `.squad/decisions/inbox/hockney-v1.1-review-rejected.md` with the full
  findings.
- **Verdict: REJECTED** (issue #1's fix specifically; issue #2 stands
  approved on its own merits). Fenster is locked out of
  `lib/scheduler.sh`'s close-pruning logic for this revision cycle per
  reviewer-protocol. Naming **Keaton** (Lead) as fix agent — not the
  author of this revision, and already familiar with this area of
  `lib/scheduler.sh` from the prior v1 lock-scope fix.

## Re-review: Keaton's `state_change_seq` lineage fix (2026-08-18)

- Re-reviewed Keaton's second fix attempt for issue #1's "more serious
  half" (recycled `pane_id` stale suppression). Design: `demotion_seq`
  state field records the `state_change_seq` observed at each demotion;
  new `_lineage_trusted()`/`_forget_stale_pane()` verify, at
  classification time, that inherited suppression/demotion bookkeeping
  belongs to the same continuously-live pane (missing baseline or a seq
  regression wipes the history and judges the pane fresh).
- Ran the suite myself (did not take 15/15 on faith): confirmed
  `regression_id_recycle_suppression.sh` now passes for the right
  reason (missing-baseline branch, not incidental reordering).
- Independently investigated `state_change_seq`'s real scope against
  the live herdr 0.8.0-preview binary (read-only, did not restart the
  live server): values are tightly clustered across heterogeneous
  panes/workspaces/agent-kinds, strong evidence it's a global/
  server-wide counter, not per-pane as Keaton's writeup ambiguously
  implied. Judged this refines rather than undermines the fix — a
  full-server-restart reset of one shared counter is architecturally
  safer to assume than N independent per-pane resets. The one
  un-provable link (does this counter actually reset on a real
  restart?) remains unverified by either of us (neither could safely
  restart Shun's live session), but the failure mode if wrong is "no
  worse than the pre-fix bug," not a new regression — not blocking.
- Verified upgrade safety directly: fed a pre-1.0.1-shaped `state.json`
  (no `demotion_seq` key at all) through `_forget_stale_pane`'s jq
  pipeline — no crash, correct output. jq's null-safe indexing handles
  the missing-key case; nothing here is bash `set -u`-sensitive.
- Wrote and ran a new regression test,
  `tests/cases/regression_suppression_survives_lineage_check.sh`,
  specifically targeting the biggest risk in this design: does ordinary
  (non-regressing) seq advancement for a genuinely continuous pane ever
  get mistaken for "different pane" and erase legitimate suppression?
  Confirmed no — a pane already at the suppression threshold correctly
  stays suppressed as its own seq climbs normally. Suite now 16/16.
- Re-traced §9 (single `agent focus` call site, unchanged reachability),
  §6.4 determinism/lock discipline (`_forget_stale_pane`'s mutation runs
  entirely inside the existing Phase-3 lock, no new lock calls,
  deterministic given identical input state), and swept §5/§10/
  `mode=off`/§6.2/Fenster's issue #2 work — all clean.
- Confirmed `bash -n` + `shellcheck -x` clean against the actual macOS
  bash 3.2.57 on this machine, and that the `awk`-based numeric
  comparisons in `_lineage_trusted` are portable (BSD/GNU awk).
- One non-blocking nit: `CHANGELOG.md`'s `## 1.0.1` entry text is now
  stale — it still describes the old presence-based fix's "stops being
  a hard guarantee across a restart" caveat, which this lineage fix is
  specifically meant to close. Flagged for Verbal/Keaton to update the
  CHANGELOG text or bump to 1.0.2; not gating this verdict.
- Wrote
  `.squad/decisions/inbox/hockney-keaton-lineage-fix-approved.md` with
  full findings.
- **Verdict: APPROVED WITH NITS.** Both prior blockers are genuinely
  closed. The residual restart-reset uncertainty is well-evidenced,
  honestly disclosed, and fails safe — not a blocker. Release may
  proceed at 1.0.1 (with the CHANGELOG nit ideally picked up first).
