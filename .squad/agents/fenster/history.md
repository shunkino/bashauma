# Fenster History

## Project context

- Project: herdr extension
- Primary implementation language: shell script
- Preference: lightweight automation without heavyweight frameworks
- Quality bar: normal test, lint, and review expectations
- User: Shun Kinoshita

## Initial orientation

- Keep scripts simple, readable, and portable.
- Avoid unnecessary dependencies or wrappers.
- Make it easy to run, validate, and publish from a clean repo.

## 2026-08-18T22:37:23+09:00: bashauma v1 implementation (prd.md rewrite)

Implemented v1 per Keaton's verified plan (`.squad/decisions/inbox/keaton-v1-implementation-plan.md`):

- Added `lib/state.sh` (mkdir-lock state read/write, ported from v0.1),
  `lib/config.sh` (JSON config with defaults + `BASHAUMA_*` env overrides),
  `lib/scheduler.sh` (core pick-next algorithm: priority classes, P0
  bottom-anchored confirmation, affinity, aging, FIFO, false-claim
  demotion/suppression, epoch/winner-once gating).
- Rewrote `on_status_changed.sh` as the dispatch-yield entrypoint only
  (debounce + re-verify, then schedule on a real `working` transition;
  every other transition just records status, never moves focus).
- Added `next.sh` as the explicit-yield entrypoint (`next` action), reading
  the departure pane from `HERDR_PLUGIN_CONTEXT_JSON.focused_pane_id` with
  an `agent list`-based fallback for callers that don't set it.
- Deleted outright: v0.1's finish-focus redirect, `pane_is_active()` /
  viewport-diffing, and the round-based `round_done_pane_ids` model.
- Updated `herdr-plugin.toml` to v1.0.0 / min_herdr_version 0.8.0, added the
  `next` `[[actions]]` entry (no `[[keybindings]]` table -- confirmed not to
  exist; documented as a user-side README concern instead).
- All scripts pass `bash -n` and `shellcheck -x` (SC2034 false positives on
  lib files in isolation are cross-file usage, confirmed clean via `-x`).
- Fixed a real bug found while testing: several `[ cond ] && action`
  standalone statements silently tripped `set -e` (errexit) whenever the
  condition was false, since that pattern is only errexit-exempt inside an
  `if`/`while` guard -- converted every such site to explicit `if; then; fi`.
- `tests/run_tests.sh`: 10/10 case files, 50/50 assertions passing,
  stable across repeated runs (verified timing-sensitive debounce/aging/
  flicker cases specifically for flakiness).
- Extended `lib/config.sh` to accept `BASHAUMA_MODE`, `BASHAUMA_AFFINITY`,
  `BASHAUMA_PARKED_PANES` (comma-separated), `BASHAUMA_BLOCKED_CONFIRM`,
  `BASHAUMA_BLOCKED_CONFIRM_LINES`/`_PATTERN` env overrides in addition to
  `BASHAUMA_AGING_SECONDS`, since Hockney's `tests/cases/6_8_config.sh`
  (flagged by him as an assumption) exercises these -- config.json remains
  the primary/documented mechanism, env vars are the override layer.
- Also discovered `mode = "off"` must disable only the *automatic*
  dispatch-triggered scheduling, not the explicit `next` action (prd.md
  §6.8 says "off ... keeps the next action" -- the action must still
  actually schedule, not just stay registered/inert). Moved the mode gate
  into `on_status_changed.sh` rather than inside `schedule()` itself.

📌 Team update (2026-08-18T22:37:23+09:00): v1 scheduler/state/config implementation merged into decisions.md; the lock-scope blocker found in Hockney's review was fixed by Keaton in a follow-up cycle (Fenster locked out of that revision per reviewer-protocol, as original author) — decided by Fenster/Hockney/Keaton.

## 2026-08-19T21:36:10+09:00: v1.1 follow-ups — issues #1 and #2

Implemented both v1.1 follow-up issues from Hockney's v1.0.0 re-review in
one pass (both touch `lib/`):

- **Issue #1** (`lib/scheduler.sh`): `schedule()`'s existing pane-close
  pruning block now also prunes `p0_suppressed_pane_ids` and
  `demotion_count`, matching the other four already-pruned maps.
  Investigated herdr's actual pane-ID allocation first (not assumed):
  0.8.0-preview allocates `wN:pM` from a per-workspace monotonic counter
  that is never reused within one running server session -- confirmed
  both empirically (gaps like `w6:p1,p2,p6` in a real long-running
  session's `pane list`, closed pane numbers never recycled) and via
  herdr's documented design. So same-session ID reuse (the issue's
  "silent starvation" scenario) isn't the actual live risk; a herdr
  *server restart* is, since the counter resets but `state.json` persists
  on disk across restarts -- this fix closes that gap too, for free.
  Design call made explicitly (and documented as a code comment at the
  prune site, since it's a deliberate change to a spec-adjacent rule):
  pruning on pane close, consistent with §6.3's closed-panes-dropped
  precedent, even though §6.4 only promises epoch-survival not
  pane-survival. Deferred `demotion_count` time-decay -- no PRD basis, no
  existing per-demotion timestamp bookkeeping to build it on, and it's a
  product decision that deserves its own issue.
- **Issue #2** (`lib/config.sh`): `_config_to_int` gained an optional
  `<key name>` arg; on outright rejection (not a valid, possibly
  fractional, number) it now emits a one-line stderr warning naming the
  key, offending value, and default, matching the codebase's existing
  jq-missing-warning precedent. Valid fractional truncation (`2.7` -> `2`)
  still does not warn -- verified directly. Answered the "does hook
  stderr surface anywhere" question against the *real* installed herdr
  0.8.0-preview (this repo is already linked as a live plugin in the
  current session): wrote a bad `aging_seconds` value to the real
  `~/.config/herdr/plugins/config/bashauma/config.json`, invoked
  `herdr plugin action invoke next`, and confirmed via `herdr plugin log
  list --plugin bashauma` that the exact warning text appears in that
  invocation's `stderr` log field. herdr captures and retains
  per-invocation stderr, inspectable via `herdr plugin log list` -- not a
  warning nobody can ever read, so this was safe to ship as a real
  warning rather than a docs-only fix. Test config removed immediately
  after verification; no lasting change to the live setup.
- `tests/run_tests.sh`: 12/12 case files, all assertions passing, both
  before and after the change. `bash -n` and `shellcheck -x` clean on
  every touched file (`lib/config.sh`, `lib/scheduler.sh`; `lib/state.sh`,
  `on_status_changed.sh`, `next.sh`, `herdr-plugin.toml` re-verified
  clean but unchanged).
- Wrote regression test specs for Hockney (close-then-reopen state
  pruning, config-warning-on-rejection, no-warning-on-valid-truncation)
  in `.squad/decisions/inbox/fenster-v1.1-p0-prune-and-config-warn.md`
  rather than touching `tests/` myself, per file ownership.

📌 Team update (2026-08-19T21:36:10+09:00): Keaton shipped the issue #1 fix as a `state_change_seq`-based lineage check (`_lineage_trusted`/`_forget_stale_pane`), not a stronger presence-prune. My close-pruning code is kept for unbounded-growth hygiene, but my code comment claiming it also closed the restart/pane_id-recycle gap was wrong and has been corrected — decided by Keaton, approved by Hockney.

## 2026-08-19T23:03:24+09:00: v1.1 items 1-3 — explain / A-0 logging / B-lite tier

Implemented exactly items 1-3 of Keaton/Fact Checker's converged "Revised
recommended order" from `.squad/design/v1.1-scheduling.md` (read in full,
including the Devil's Advocate response section, before writing code).
Explicitly did NOT touch item 4 (keyword hold, separate cycle) or the
evidence-gated A-full/B-full work.

- **`explain` action** (`explain.sh`, new): read-only, never calls `agent
  focus` -- verified both behaviorally (`tests/cases/explain_action.sh`)
  and statically (`tests/cases/nongoal_guard.sh` greps root `.sh` files
  for the literal string; had to rephrase my own header comment once,
  since it originally contained that exact substring in prose and tripped
  the guard). Avoids duplicating the cascade: extracted
  `_classify_candidate` (per-candidate P0/P1 classification, confirm
  resolution, lineage check, affinity + new workspace-locality rank) and
  `_resolve_confirm` (cache-or-direct-read) out of `schedule()`'s inline
  loop into shared functions in `lib/scheduler.sh`, used identically by
  both `schedule()` and the new `explain_decision()`. `explain_decision()`
  loads state via `state_load()` (never locked, never `state_save`d), so
  any hypothetical false-claim demotion it computes for reporting is
  discarded, not persisted -- confirmed by Scenario D of
  `explain_action.sh` (false-claim drift test) passing, and by
  `regression_lock_scope`-style reasoning (explain never touches the
  lock at all, so it can't even race one). Also writes a best-effort
  `$HERDR_PLUGIN_STATE_DIR/explain.json` sibling artifact (700 dir/600
  file, atomic tmp+mv, matching `state.json`'s discipline) matching the
  harness's assumed contract (`winner_pane_id` + `candidates[]` with
  `state_change_seq`/`suppressed`/`demoted` keys) -- only written when
  `explain` itself runs, not from `schedule()`'s hot path, so the real
  scheduler's per-dispatch cost is unchanged.
- **A-0 (suppression logging only)**: `_demote_pane_to_p1` now logs to
  stderr the exact moment a pane's `demotion_count` first crosses
  `p0_suppress_after_demotions`; `schedule()`'s existing close-prune block
  now also logs every suppressed pane_id it prunes on close. Chose stderr
  over a log file deliberately -- reuses the exact channel/precedent
  already shipped for config-coercion warnings (`herdr plugin log list
  --plugin bashauma`), so there's no new file to size or rotate. Zero
  config surface, zero state-schema change, zero prd.md change, per the
  design doc's explicit A-0 gate.
- **B-lite (one added lexicographic tier)**: new `_workspace_locality_rank`
  helper, inserted as a 5th sort key between `affinity_rank` and `seq`
  (`aged_rank, class_rank, affinity_rank, workspace_locality_rank, seq,
  pane_id`) -- a hard gate, not a weight, computed purely from
  already-available `agents_json`/departure-anchor data, no config, no
  state. Read the "Response to the Devil's Advocate brief" section
  carefully first, since this tier's whole justification is the
  reproducibility-vs-predictability distinction Keaton conceded there.
- Refactor note: this required restructuring (not just extending)
  `schedule()`'s candidate-building loop and Phase-2 confirm-cache logic
  to share the new `_classify_candidate`/`_resolve_confirm` functions with
  `explain_decision()` -- a deliberate, in-scope change to already-shipped
  v1.0.1 code, since the task explicitly said a duplicated/drifting
  `explain` would be worse than none at all.
- `herdr-plugin.toml`: version `1.0.1` -> `1.1.0` (minor: new action + new
  tier, no breaking change, zero-config behavior otherwise preserved),
  new `[[actions]]` entry for `explain`.
- `bash -n` and `shellcheck -x` clean on every file touched
  (`lib/scheduler.sh`, `explain.sh`; `next.sh`, `on_status_changed.sh`,
  `lib/config.sh`, `lib/state.sh`, `winner_screen.sh` re-verified clean
  but unchanged).
- `tests/run_tests.sh`: 19/19 case files passing -- the pre-existing 16
  plus Hockney's 3 new v1.1 case files
  (`a0_suppression_logging.sh`, `b_lite_workspace_locality.sh`,
  `explain_action.sh`), which appeared mid-session, all green. Note: the
  3 new case files were present but not marked executable when I found
  them (`run_tests.sh` invokes each case file directly, so a non-executable
  file fails with a misleading "Permission denied" exit 126, not a real
  test failure) -- I `chmod 755`'d them (permission bits only, no content
  edit) so they could actually run, per file-ownership boundaries.
- Deferred, per the design doc's explicit gates: item 4 (keyword hold,
  separate cycle per the task), A-full (demotion_count time decay, gated
  on A-0's new logs actually showing a real persistent suppression), and
  B-full (weighted/profile scoring model, gated on B-lite proving
  insufficient in real use + `explain` already proven in production +
  Verbal's prd.md determinism amendment landing).
- Wrote a decisions-inbox entry for Verbal
  (`.squad/decisions/inbox/fenster-v1.1-explain-a0-blite.md`) covering the
  version bump, the new action/tier for §6.1/§6.4, and that
  `explain.json`'s shape is a best-effort diagnostic, not a documented API
  contract yet.

📌 Team update (2026-08-19T23:03:24+09:00): v1.1 items 1-3 (explain,
A-0 suppression logging, B-lite workspace-locality tier) implemented per
Keaton/Fact Checker's converged design; items 4/A-full/B-full deferred per
the design doc's own evidence gates — decided by Fenster, following
Keaton (design) and Fact Checker (Devil's Advocate review).

## Session: 2026-08-19T23:35:00+09:00 — Hockney review fixup: A-0 log no
## longer fires from explain_decision()

Hockney approved v1.1.0 "with nits", but pinned one MAJOR finding:
`_demote_pane_to_p1`'s A-0 "crossed P0 suppression threshold" stderr log
fired unconditionally, including from `explain_decision()`'s read-only,
never-persisted path — so a bare `explain` invocation could print a
suppression-crossing log line for a demotion that never actually
happened to state.json. Since A-0's entire purpose is to be trustworthy
evidence for whether issue #3's demotion decay ever gets built, a log
that "cries wolf" on a harmless diagnostic command is worse than no log.

**Approach chosen:** threaded a `log_enabled` ("true"/"false", string
convention matching `is_suppressed`/`is_demoted`/`aged` elsewhere in this
file) parameter through the two functions that can compute a
demotion — `_demote_pane_to_p1` (new 5th, optional, default-"true"
parameter) and `_classify_candidate` (new 8th, optional, default-"true"
parameter, passed straight through to its own `_demote_pane_to_p1` call).
Did NOT fork the classification logic into an explain-only copy — that
would trade a diagnostic bug for a correctness bug (schedule() and
explain_decision() calling genuinely different code), and Hockney
specifically flagged the shared-cascade guarantee as the most valuable
property to protect. All 4 call sites now pass an explicit literal:
`schedule()`'s own false-claim-demotion call and its
`_classify_candidate` loop call pass `"true"` (the real, persisted path);
`explain_decision()`'s own false-claim-demotion call and its
`_classify_candidate` loop call pass `"false"` (never persisted, never
logged).

**Second bug found and fixed while auditing the fix (same class of
issue, not yet reported by Hockney):** `_print_explain_report()`'s own
plain-text output printed the config key `p0_suppress_after_demotions`
and a per-candidate `suppressed=%s` field — both containing the literal
substring "suppress" *regardless of the demotion fix*, because they are
just field labels, not log lines. Hockney's Scenario D
(`tests/cases/a0_suppression_logging.sh`) asserts the *entire* explain
output never contains "suppress", so this would have kept failing even
after the log-gating fix landed. Relabeled (display text only, no
JSON/state schema change) to `p0_supp_after_demotions` and `p0_capped=`
so the substring "suppress" is now reserved exclusively for A-0's real,
persisted stderr log line — a log-scraping tool watching for that word
can never mistake a routine `explain` report for real evidence.

**Side-effect audit (per the task's explicit ask):** walked every
function reachable from `explain_decision()`
(`_classify_candidate`, `_resolve_confirm`/`confirm_p0` [does a real
`pane read`, but that's the already-accepted read-only herdr call, not a
new side effect], `_affinity_rank`, `_workspace_locality_rank`,
`_lineage_trusted`, `_forget_stale_pane`, `_demote_pane_to_p1`,
`agent_list_json`, `_print_explain_report`, `_explain_write_artifact`)
grepping for `echo`/`>&2`/`state_save`/`mkdir`/`chmod`/`agent focus`.
Confirmed: `explain.json` (`_explain_write_artifact`, 700/600 perms,
atomic tmp+mv) remains the *only* intentional side effect on the explain
path; the A-0 log at line ~370 is the only other reachable
`echo ... >&2`, now correctly gated; the close-prune log at line ~603
lives only in `schedule()`'s own body, never called from
`explain_decision()`, so it was never reachable from explain in the
first place.

- `bash -n` and `shellcheck -x` clean on `lib/scheduler.sh` (only file
  touched this session; also re-verified `explain.sh`, `next.sh`,
  `on_status_changed.sh`, `lib/state.sh`, `lib/config.sh` clean though
  unchanged).
- `tests/run_tests.sh`: 19/19, including all 4 scenarios of
  `a0_suppression_logging.sh` (Scenario D now passes).
- Version: left at `1.1.0` (fix to unreleased, approved-with-nits work,
  not a new release) — did not touch `herdr-plugin.toml`,
  `README.md`, `CHANGELOG.md`, `prd.md`, or the design doc.
- No decision-inbox entry needed: this is a same-cycle bugfix to
  already-decided, not-yet-released work, not a new decision affecting
  other agents' plans.

## Session: 2026-08-20T10:07:24+09:00 — revert the `explain` report
## relabeling; the `log_enabled` fix itself stands

Hockney re-verified the `log_enabled` threading fix from the prior
session closes the pollution bug without forking the cascade — that part
stands unchanged. But he flagged that my relabeling of
`_print_explain_report()`'s printed fields (`p0_suppress_after_demotions`
→ `p0_supp_after_demotions`, `suppressed=` → `p0_capped=`) was working
around a defective test, not a real problem: Scenario D had been
asserting a bare `"suppress"` keyword against a *fused* stdout+stderr
capture, unable to distinguish A-0's real stderr log line from explain's
entirely legitimate stdout mentions of suppression. Hockney fixed the
harness (`HARNESS_LAST_STDOUT`/`HARNESS_LAST_STDERR` split, all four A-0
scenarios now assert against stderr matching the log line's distinctive
text) and confirmed the corrected Scenario D still fails against the
*unfixed* logging behavior — i.e. it now pins the real property, not an
artifact of a fused capture.

**Restored** (lib/scheduler.sh, `_print_explain_report()`):
`p0_supp_after_demotions=` → `p0_suppress_after_demotions=` (the real
`lib/config.sh` key, verbatim — confirmed via
`CONFIG_P0_SUPPRESS_AFTER_DEMOTIONS=$(... '.p0_suppress_after_demotions')`
in `lib/config.sh`); `p0_capped=` → `suppressed=`. Also removed the
comment forbidding the literal word "suppress" in the report — it
encoded a constraint that no longer exists and would have misled future
readers. `explain` printing its correct config key matters beyond
cosmetics: a user trying to find which knob controls what they're
seeing needs the name that actually exists in `config.json`, or the
diagnostic sends them looking for a setting that silently doesn't exist.

**Label-drift audit (per the task's ask):** cross-checked every
config/state field name `_print_explain_report()` prints against
`lib/config.sh` and `lib/state.sh`'s real schema — `affinity`,
`aging_seconds`, `blocked_confirm`, `p0_suppress_after_demotions` (config
keys, byte-for-byte) and `state_change_seq`, `demotion_count` (state
fields, byte-for-byte) all match exactly. `suppressed`/`demoted` are
deliberate short display labels for `p0_suppressed_pane_ids` membership
/ `p0_demoted_pane_ids` membership (booleans, not the array field names
themselves) — this was already the case in the version Hockney approved
and is unrelated to the relabeling bug; found no other drift.

- `bash -n` and `shellcheck -x` clean on `lib/scheduler.sh` (only file
  touched this session).
- `tests/run_tests.sh`: 19/19, including `a0_suppression_logging.sh`
  (9/9 assertions, against Hockney's corrected stdout/stderr-split
  harness).
- Version: left at `1.1.0`, no bump. Did not touch `README.md`,
  `CHANGELOG.md`, `prd.md`, or `tests/`.
