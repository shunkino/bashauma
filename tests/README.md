# bashauma tests

A tiny, dependency-free shell test suite for the `bashauma` scheduler. No
bats, no test framework — just POSIX `sh`, `bash`, and `jq` (both already
required by the plugin itself).

> 📌 **Proactive test suite.** These tests were written directly from
> `prd.md` while Fenster's v1 scheduler implementation was still in
> progress. Expect failures until that implementation lands — see
> "Entrypoint indirection" below for how the harness is wired to plug into
> whatever Fenster ships.

## Running

```sh
tests/run_tests.sh                 # run every case
tests/run_tests.sh 6_1 6_5         # run only cases whose filename matches
```

Exit code is non-zero if any assertion in any case failed. Output is a
colored (when attached to a tty) pass/fail line per case plus a final
summary.

## Layout

```
tests/
  run_tests.sh            # the runner: discovers and executes tests/cases/*.sh
  lib/harness.sh           # assert_eq / assert_contains / assert_exit_code,
                           # setup_test/teardown_test, herdr-stub scripting
                           # helpers, invoke_status_changed/invoke_next
  fixtures/bin/herdr       # fake `herdr` CLI: replays scripted responses for
                           # agent list / agent get / agent focus / pane read /
                           # plugin pane open, and logs every call
  cases/*.sh               # one file per PRD section/requirement
```

## Entrypoint indirection

Keaton's v1 interface wasn't finalized when this suite was written, so every
test drives the scheduler through two overridable indirection points
(documented at the top of `tests/lib/harness.sh`):

| Variable | Default | Fires on |
| --- | --- | --- |
| `BASHAUMA_SCHEDULER_CMD` | `on_status_changed.sh` | dispatch yield (`pane.agent_status_changed`), prd.md §6.1 |
| `BASHAUMA_NEXT_CMD` | `next.sh` | explicit yield (the `next` action), prd.md §6.1 |
| `BASHAUMA_EXPLAIN_CMD` | `explain.sh` | the v1.1 `explain` action (design: `.squad/design/v1.1-scheduling.md`) — **NOT a yield point** |

`explain`'s output is a plain human-readable stdout report
(`_print_explain_report()` in `lib/scheduler.sh`), with the winning
candidate's line ending in the literal marker `<-- WINNER` — parsed by
`explain_winner_pane_id()` in `tests/lib/harness.sh`. If that report
format ever changes, only `explain_winner_pane_id()` needs updating; the
intent of each check should not need to change.

If the real implementation uses different file names, either rename the
files to match, or export the variables (e.g. in CI, or ad-hoc on the
command line) to point at the real entrypoints. Nothing else needs to
change.

### Asserting on output: `HARNESS_LAST_STDOUT` / `HARNESS_LAST_STDERR` / `HARNESS_LAST_OUTPUT`

Every `invoke_status_changed` / `invoke_next` / `invoke_explain` call sets
three variables (`tests/lib/harness.sh`'s `_harness_run_captured`):

- `HARNESS_LAST_STDOUT` — stdout only.
- `HARNESS_LAST_STDERR` — stderr only.
- `HARNESS_LAST_OUTPUT` — both concatenated (stdout first), kept for
  older tests that only ever assert substring *presence*, not which
  stream a message landed on.

**Prefer the split variables for any new assertion**, and be specific
about which stream you actually mean. A-0's real diagnostic log lines
(`_demote_pane_to_p1`'s threshold-crossing log, `schedule()`'s
close-prune log) are stderr-only by design — assert against
`HARNESS_LAST_STDERR` when checking for them, not the fused
`HARNESS_LAST_OUTPUT`. This isn't cosmetic: `explain`'s legitimate stdout
report discusses suppression by name (the `p0_suppress_after_demotions`
config key, a per-candidate `suppressed=` field) as part of its normal,
correct job, and a bare keyword check against the fused stream can't tell
that apart from A-0's real log line actually firing —
`tests/cases/a0_suppression_logging.sh` hit exactly this
(2026-08-20 Hockney review follow-up) and had to be corrected to check
`HARNESS_LAST_STDERR` for the log line's distinctive text, not
`HARNESS_LAST_OUTPUT` for a bare "suppress" substring.

A few individual cases (`6_4_affinity_aging_fifo_falseclaim.sh`,
`6_8_config.sh`) also assume specific *config* wiring (e.g.
`BASHAUMA_AGING_SECONDS`, `BASHAUMA_MODE`, `BASHAUMA_PARKED_PANES`,
`BASHAUMA_BLOCKED_CONFIRM` environment variables, mirroring the existing
`BASHAUMA_DEBOUNCE_SECONDS` convention). Each such assumption is called out
in a comment at the top of the file it appears in — update the env var
names there if config ends up wired some other way; the assertions
themselves should still hold.

When a configured entrypoint doesn't exist yet (or isn't executable), the
relevant assertion is reported as a real failure via `fail_not_implemented`,
not silently skipped — per-task expectation, this suite should fail loudly
and informatively until the real implementation lands, not pass by doing
nothing.

## Writing a new case

1. Create `tests/cases/<name>.sh`, executable, starting with:

   ```sh
   #!/bin/bash
   set -u
   . "$(dirname "$0")/../lib/harness.sh"
   ```

2. For each scenario: call `setup_test` (fresh temp
   `HERDR_PLUGIN_STATE_DIR` + herdr-stub sandbox on `PATH`), script the fake
   `herdr` CLI's responses, invoke the scheduler, assert, then
   `teardown_test`.
3. End the file with `harness_report_and_exit` so the runner sees the right
   exit code.

### Scripting the herdr stub

```sh
setup_test

stub_set_agent_list '[
  {"pane_id":"w1:p1","agent_status":"working","state_change_seq":1,
   "tab_id":"t1","workspace_id":"ws1","cwd":"/repo","focused":true},
  {"pane_id":"w1:p2","agent_status":"idle","state_change_seq":2,
   "tab_id":"t1","workspace_id":"ws1","cwd":"/repo","focused":false}
]'

# Optional: script a `pane read` response for confirmation-check tests
# (prd.md §6.2). The stub returns raw text, matching real `herdr pane read`.
stub_set_pane_read "w1:p2" <<'EOF'
│ ↑/↓ to select · enter to confirm · esc to cancel │
EOF

# Optional: script a different `agent get` response than agent_list.json,
# for debounce/flicker tests (prd.md §6.6).
stub_set_agent_get "w1:p2" '{"pane_id":"w1:p2","agent_status":"idle", ...}'

# Optional: simulate `agent list` / `agent focus` failing outright.
stub_fail_agent_list
stub_fail_focus

invoke_status_changed "w1:p1" "working"   # dispatch yield
# or: invoke_next                          # explicit yield

assert_focus_called_with "w1:p2" "message"
assert_focus_not_called "message"
assert_winner_fired_count 1 "message"

teardown_test
harness_report_and_exit
```

Every real (non-stubbed) `herdr` invocation is also logged verbatim to
`$HERDR_STUB_LOG` (one line per call) if you need to assert on something the
higher-level helpers don't cover — read it with `herdr_invocation_log`.

## Assertions

- `assert_eq actual expected [message]`
- `assert_contains haystack needle [message]`
- `assert_not_contains haystack needle [message]`
- `assert_exit_code expected actual [message]`
- `assert_focus_called_with pane_id [message]`
- `assert_focus_not_called [message]`
- `assert_focus_call_count n [message]`
- `assert_winner_fired_count n [message]`
- `fail_not_implemented message` — use when an `invoke_*` helper returns 127

Assertions don't abort the case file on the first failure; every assertion
in the file runs, and `harness_report_and_exit` reports/exits based on the
total failure count. This gives a full picture per case instead of one
failure at a time.

## What's covered

One case file per PRD requirement group (see the header comment in each file
for the exact clause it tests):

- `6_1_yield_points.sh` — dispatch yield and explicit `next` yield both move focus
- `6_2_priority_classes.sh` — P0 before P1; blocked_confirm pass/fail
- `6_2_bottom_anchoring.sh` — stale scrollback mentions don't falsely confirm P0
- `6_3_epoch.sh` — fed-pane exclusion, closed-pane pruning, winner fires once
- `6_4_affinity_aging_fifo_falseclaim.sh` — affinity order, aging, FIFO, false-claim demotion
- `6_5_non_dispatch_no_focus.sh` — the §9 hard invariant: non-dispatch status changes never move focus
- `6_6_flicker.sh` — debounced/re-verified flicker doesn't count as a yield
- `6_8_config.sh` — `mode=off`, `parked_panes`, `blocked_confirm=false`
- `10_edge_cases.sh` — zero/one agent, all-blocked, repeat dispatch, `agent list` failure
- `nongoal_guard.sh` — static grep guard: no `herdr notification show`, no stray `agent focus`

Plus regression cases added during Hockney's post-implementation review pass
(each documents, in its own header, the exact defect it pins and why it's
expected to fail until fixed):

- `regression_lock_scope.sh` — the state lock must not be held across
  external `herdr` calls (`agent list`, per-candidate `pane read`); proves
  it deterministically via `lock_held_during.log` (see
  `assert_no_calls_while_state_lock_held` / `calls_made_while_state_lock_held`
  in `lib/harness.sh`), no timing race required.
- `regression_fractional_aging_seconds.sh` — a fractional (but PRD-legal)
  `aging_seconds`/`BASHAUMA_AGING_SECONDS` crashes `schedule()`'s bash
  integer arithmetic and silently drops the yield.
- `regression_id_recycle_suppression.sh` — a pane_id recycled after a herdr
  server restart must not silently inherit a stale P0 suppression record
  from the previous, now-gone agent that used to hold that ID.
- `regression_suppression_survives_lineage_check.sh` — the recycled-ID
  lineage-verification fix (`_lineage_trusted`/`_forget_stale_pane`) must
  not itself disable suppression for a genuinely continuous pane: ordinary,
  always-forward `state_change_seq` movement during real operation must
  never be mistaken for evidence of a different pane.
- `regression_close_reopen_pruning.sh` — suppression/demotion bookkeeping
  is pruned when a pane closes, while other panes' entries survive.
- `regression_config_warning.sh` — `_config_to_int` warns to stderr (exact
  message text) on outright-invalid config values, and stays silent for
  valid-but-fractional truncation.

## v1.1 (design: `.squad/design/v1.1-scheduling.md`)

> 📌 Written PROACTIVELY, ahead of Fenster's implementation of the same
> three items — see each file's header comment for the design section it
> targets and any output-contract assumptions it had to make.

- `explain_action.sh` — the new `explain` action: must never call `agent
  focus` under any input (empty queue, all-blocked, `agent list` failure —
  it is explicitly NOT a yield point), and must report exactly the same
  winner `next` actually picks for identical, non-obvious queue state
  (guards against a duplicated/stale copy of the pick-next cascade drifting
  from the real one).
- `a0_suppression_logging.sh` — A-0: logs every suppression-threshold
  crossing and every suppressed-pane close-prune, and — just as
  important — does NOT fire on ordinary operation with no such event (a
  log that cries wolf is useless as the evidence it exists to gather).
- `b_lite_workspace_locality.sh` — B-lite: the new workspace-locality
  lexicographic tier (`aged_rank, class_rank, affinity_rank,
  workspace_locality_rank, seq, pane_id`) is a no-op under default (`tab`)
  affinity, has an effect only with `affinity=none`, never overrides a
  confirmed P0 pane, never overrides aging promotion (the starvation
  guarantee), and keeps the pick deterministic for identical queue state.
