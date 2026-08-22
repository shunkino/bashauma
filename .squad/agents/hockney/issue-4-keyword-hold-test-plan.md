# Test plan: GitHub issue #4 — keyword-based transition hold

**By:** Hockney (QA / Reviewer)  
**Date:** 2026-08-22T10:14:20+09:00  
**Status:** Proactive / anticipatory — prepared before Keaton's go/no-go. Adjust if the accepted implementation contract changes.

## Contract to pin

Issue #4 adds a dispatch-only “hold” heuristic: on a dispatch yield, inspect only the departure pane's bottom `hold_check_lines` non-empty visible lines. If a configured hold keyword/pattern matches and the pane is not hold-exempt, perform normal dispatch bookkeeping but skip the candidate pick/focus. `schedule()` should therefore accept an explicit `is_dispatch_yield` boolean: `on_status_changed.sh` passes true; `next.sh` passes false.

Critical invariant: **the hold block must never run for explicit `next`**. `next` is the user’s escape hatch and must always schedule normally.

## Proposed tests

### `tests/cases/hold_dispatch_only_next_escape.sh`

- **Purpose:** Pin dispatch-only behavior and the `next` escape hatch. This is the exact test that must fail if someone later wires hold matching into `next`.
- **Setup:** `config.json` with `hold_keywords: ["run the following command"]`; departure pane `p_leave` is focused/working and its pane-read fixture includes `run the following command`; candidate `p_other` is idle.
- **Assertions:**
  1. `invoke_status_changed "p_leave" "working"` exits 0, emits the exact hold log on stderr, does **not** call `agent focus`, and marks `p_leave` fed while leaving `last_winner_pane_id` unchanged/null.
  2. Without changing the departure scrollback, `invoke_next "p_leave"` focuses `p_other` and does **not** emit a second hold log.
  3. `herdr_invocation_log` for the `next` half contains no `pane read p_leave --source visible` hold check. Candidate P0 confirmation reads, if any, remain allowed, but this scenario uses only idle candidates to make the expected count zero.
- **Harness gaps:** None. Existing `invoke_status_changed`, `invoke_next`, `HARNESS_LAST_STDERR`, `focus_calls`, and `herdr_invocation_log` are sufficient.

### `tests/cases/hold_bottom_anchoring.sh`

- **Purpose:** Prove hold matching is bottom-anchored like `6_2_bottom_anchoring.sh`: stale scrollback above the bottom window must not hold.
- **Setup:** `hold_keywords: ["open your browser"]`, default `hold_check_lines` first. Departure pane text contains `open your browser` near the top followed by 16 non-empty unrelated lines; candidate `p_other` idle. Add a second scenario with the same keyword inside the bottom 15 lines. Add a third scenario with `hold_check_lines: 2` to prove the knob changes the bottom window.
- **Assertions:**
  1. Stale-above-bottom keyword: scheduler focuses `p_other`, no hold log.
  2. Bottom-window keyword: no focus, exact hold log.
  3. With `hold_check_lines: 2`, a keyword on the third-from-bottom non-empty line does not hold, while moving it to bottom 2 does.
- **Harness gaps:** None.

### `tests/cases/hold_default_inert_transcript.sh`

- **Purpose:** Prove “ships inert” as byte-for-byte external behavior, not merely “a happy path still focuses something.”
- **Setup:** No `config.json` and no hold env overrides. Use a deterministic no-runnable dispatch case: departure `p_leave` is the only open working pane, so existing behavior is debounce `agent get`, `agent list`, epoch drain, winner popup, no candidate timestamps.
- **Assertions:**
  1. Exact `herdr_invocation_log` equals today’s expected transcript; in particular it contains no `pane read p_leave --source visible`.
  2. Canonical `state.json` equals the exact expected JSON for this scenario.
  3. `HARNESS_LAST_STDERR` is empty.
  4. Repeat with explicit `{"hold_keywords": []}` and assert the same exact transcript/state/stderr.
- **Why this proves no default behavior change:** It pins the full observable command transcript plus final state, including absence of the new read/log path, instead of checking only the final focus/winner result.
- **Harness gaps:** None, though adding a small `assert_herdr_invocation_log_eq` helper would reduce boilerplate.

### `tests/cases/hold_event_logging.sh`

- **Purpose:** Pin mandatory A-0 stderr visibility for silent holds.
- **Setup:** `hold_keywords: ["run the command (y/n)?"]`; departure pane bottom line contains exactly `Please run the command (y/n)?`; one idle candidate exists.
- **Assertion:** `HARNESS_LAST_STDERR` must equal exactly:

  ```text
  bashauma: held on p_leave, matched "run the command (y/n)?"
  ```

  Also assert no focus call and no stdout requirement. If the implementation adds timestamps, reject that for this test: a dynamic field weakens the exact-text contract and makes the log harder to assert the way `regression_config_warning.sh` does.
- **Harness gaps:** None; split stderr capture already exists.

### `tests/cases/hold_next_deexempts_same_pane.sh`

- **Purpose:** Prove single-strike de-exemption engages after the user immediately contradicts a hold with `next`.
- **Setup:** `hold_keywords: ["navigate to"]`, `hold_suppress_after: 1`. `p_leave` is focused/working with bottom text `navigate to settings`; `p_other` idle.
- **Assertions:**
  1. First dispatch from `p_leave` holds: no focus, hold log, `hold_count.p_leave == 1`, `hold_seq.p_leave` equals observed `state_change_seq`.
  2. Immediate `invoke_next "p_leave"` focuses `p_other` and records the false-hold/de-exemption state (`false_hold_count.p_leave == 1` or the final shipped equivalent).
  3. A later dispatch yield from the same continuous pane (`state_change_seq` advanced, still >= recorded `hold_seq`) with the same matching text does **not** hold; it focuses the next candidate and emits no hold log.
- **Harness gaps:** None for “immediate next.” If Keaton keeps a `hold_quick_next_seconds` timeout and wants boundary tests, the harness needs clock injection (e.g. `BASHAUMA_NOW_MS`) because `_now_ms` is not controllable today.

### `tests/cases/regression_hold_deexemption_id_recycle.sh`

- **Purpose:** Ensure a recycled pane ID does not inherit stale hold exemption — the hold equivalent of `regression_id_recycle_suppression.sh`.
- **Setup:** Seed `state.json` with a prior exemption for `p_recycled`: `hold_count`, `last_hold_at`, `hold_seq: 50`, `false_hold_count: 1`, `last_false_hold_at`. First live `agent list` already contains a new `p_recycled` with lower `state_change_seq: 3`, focused/working, and matching hold keyword; `p_other` idle.
- **Assertion:** Correct lineage failure wipes stale hold state and treats `p_recycled` as fresh, so the dispatch holds: no focus, exact hold log, and state records a new `hold_seq` of 3. A buggy implementation that trusts the stale exemption will focus `p_other` and fail.
- **Harness gaps:** None.

### `tests/cases/regression_hold_deexemption_survives_lineage_check.sh`

- **Purpose:** Ensure the lineage check does not disable a legitimate exemption for a continuous pane — the hold equivalent of `regression_suppression_survives_lineage_check.sh`.
- **Setup:** Seed `state.json` with `hold_seq.p_noisy: 15`, `false_hold_count.p_noisy: 1`, plus required hold timestamps. Live `agent list` contains the same focused/working `p_noisy` with `state_change_seq: 20` and matching keyword, plus idle `p_other`.
- **Assertion:** Since observed seq advanced normally, lineage is trusted; `p_noisy` remains hold-exempt, dispatch schedules normally and focuses `p_other`; stale-forget must not delete the exemption state.
- **Harness gaps:** None.

### `tests/cases/hold_config_matching.sh`

- **Purpose:** Cover config surface and matching semantics.
- **Setup / assertions:**
  1. `hold_keywords: ["run the command (y/n)?"]` matches literal text containing parentheses and `?`; hold fires. This fails if keywords are accidentally treated as regex.
  2. `hold_keywords: ["a.b"]` does **not** match `axb`, then does match `a.b`; proves fixed-string, not regex wildcard semantics.
  3. `hold_keywords: ["-danger"]` matches `-danger`; proves the implementation uses `grep -Fqi --` or `grep -Fqi -e`, not an injectable bare pattern.
  4. `hold_keywords: ["OPEN YOUR BROWSER"]` matches `open your browser`; proves case-insensitive matching.
  5. `hold_pattern: "run (this|that)"` with empty keywords matches `please run this`; proves the ERE override works intentionally.
  6. `hold_check_lines` and `hold_suppress_after` load from `config.json` as numeric knobs; invalid-value warning coverage can mirror `regression_config_warning.sh` if Keaton extends `_config_to_int` to these keys.
- **Harness gaps:** None for behavior. Exact invalid-config warning tests depend on the implementation specifying fallback-warning text for the new numeric keys.

### `tests/cases/hold_determinism.sh`

- **Purpose:** Pin prd.md §6.4 determinism: identical queue state produces identical outcome, whether the hold fires or not.
- **Setup:** Two fresh sandboxes with identical config/state/agent list.
  - Scenario A: no hold match, tied idle candidates whose only final differentiator is pane_id; expect the same winner both runs.
  - Scenario B: hold match on departure pane; expect the same no-focus outcome both runs. Normalize dynamic timestamp fields (`last_hold_at`, `last_false_hold_at`) before comparing state if they are present.
- **Assertions:** Winner/no-winner and canonical normalized state are identical across the two runs. Scenario A’s winner is the lexicographic pane-id tiebreaker; Scenario B has zero focus calls in both runs and identical non-timestamp state.
- **Harness gaps:** No required gap; the case can implement normalization inline with `jq`. A reusable `canonical_state_without_timestamps` helper would be nice.

### `tests/cases/hold_cost_one_departure_read.sh`

- **Purpose:** Enforce cost: exactly one extra `herdr pane read` per dispatch yield, for the departure pane only; never one per candidate.
- **Setup:** `hold_keywords: ["please stay here"]`; departure `p_leave` working. Use five idle candidates so no existing blocked-confirmation reads are expected. Give `p_leave` non-matching text in one scenario and matching text in another.
- **Assertions:** For each dispatch yield, `herdr_invocation_log | grep -c '^pane read '` is exactly `1`, and the sole line is `pane read p_leave --source visible`. No `pane read` calls for idle candidates. Add a companion `invoke_next` scenario with the same config/text and assert zero departure hold reads.
- **Harness gaps:** None; the stub already logs every invocation. A helper like `pane_read_calls_for <pane>` would reduce repeated grep/awk.

## Harness changes I would make only if needed

1. **Clock injection:** Optional, only if the final design keeps a quick-next timeout and we want boundary tests for “too late to count.” Add `BASHAUMA_NOW_MS` support in `_now_ms` or a test-only wrapper.
2. **Log/read-count helpers:** Not required; current `herdr_invocation_log` and `HARNESS_LAST_STDERR` are enough. Helpers would improve readability only.
3. **Config warning text for new numeric keys:** If `hold_check_lines` / `hold_suppress_after` use `_config_to_int`, extend `regression_config_warning.sh` or add a hold-specific warning case once exact text is implemented.

## Non-goals for this plan

- Do not implement issue #4 in `lib/`.
- Do not test real `herdr plugin log list`; plugin stderr is already the channel current tests use for A-0/config warnings, and Herdr captures that channel for `plugin log list`.
- Do not test timer-driven self-expiry; the design rejects timer-based focus moves as preemption.
