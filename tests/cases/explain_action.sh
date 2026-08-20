#!/bin/bash
# v1.1 design (.squad/design/v1.1-scheduling.md, "Revised recommended
# order" item 1) — the `explain` action: a brand-new, read-only report of
# why the scheduler would pick what it picks. Written PROACTIVELY, ahead
# of Fenster's implementation — expected to fail until explain.sh lands.
# See tests/lib/harness.sh's header comment for explain's confirmed
# output contract (parsed from stdout's "<-- WINNER" marker line).
#
# Two properties matter more than the happy path:
#
#   1. explain is NOT a yield point (design: "directly answers... without
#      adding any new scheduling behavior"). It must never call `agent
#      focus`, under any input, including the queue-empty/all-blocked/
#      agent-list-failure edge cases explicitly called out in the task —
#      these are exactly the paths most likely to be mishandled by a
#      naive "just call schedule() and skip the last line" implementation
#      that still runs partway into focus-adjacent code.
#
#   2. explain must not DRIFT from the real cascade. Fenster was told to
#      make explain read the real ordering logic, not reimplement it. A
#      stale/duplicated copy is worse than no explain at all, because it
#      lies with authority. Scenario D below is deliberately built so the
#      correct winner is NON-OBVIOUS from a naive re-implementation (it
#      depends on the false-claim demotion state written by a PRIOR
#      yield) — if explain's own copy of the pick-next logic doesn't
#      consult that same state, it will report a different winner than
#      `next` actually focuses.
set -u
. "$(dirname "$0")/../lib/harness.sh"

CONFIRM_HINT_LINE='│ ↑/↓ to select · enter to confirm · esc to cancel │'

# --- Scenario A: explain must never focus -- empty queue --------------------
setup_test
stub_set_agent_list '[
  {"pane_id":"p_leave","agent_status":"working","state_change_seq":1,"tab_id":"t1","workspace_id":"ws1","cwd":"/repo","focused":true}
]'
invoke_explain "p_leave"
rc=$?
if [ "$rc" -eq 127 ]; then
    fail_not_implemented "BASHAUMA_EXPLAIN_CMD (empty queue must never focus)"
else
    assert_focus_not_called "explain on an empty runnable queue must never call agent focus"
fi
teardown_test

# --- Scenario B: explain must never focus -- everything blocked, none confirm
setup_test
stub_set_agent_list '[
  {"pane_id":"p_leave","agent_status":"working","state_change_seq":1,"tab_id":"t1","workspace_id":"ws1","cwd":"/repo","focused":true},
  {"pane_id":"p_b1","agent_status":"blocked","state_change_seq":2,"tab_id":"t9","workspace_id":"ws9","cwd":"/x","focused":false},
  {"pane_id":"p_b2","agent_status":"blocked","state_change_seq":3,"tab_id":"t9","workspace_id":"ws9","cwd":"/x","focused":false}
]'
# Neither p_b1 nor p_b2 has a confirm-matching scrollback -- both demote to
# P1, per §6.2/§6.4 -- but the runnable queue is still non-empty (both are
# P1 candidates), so this specifically exercises "all-blocked, none
# confirmed" distinctly from Scenario A's genuinely-empty case.
invoke_explain "p_leave"
rc=$?
if [ "$rc" -eq 127 ]; then
    fail_not_implemented "BASHAUMA_EXPLAIN_CMD (all-blocked-unconfirmed must never focus)"
else
    assert_focus_not_called "explain when every pane is blocked (and none P0-confirmed) must never call agent focus"
fi
teardown_test

# --- Scenario C: explain must never focus -- agent list fails ---------------
setup_test
stub_fail_agent_list
invoke_explain "p_leave"
rc=$?
if [ "$rc" -eq 127 ]; then
    fail_not_implemented "BASHAUMA_EXPLAIN_CMD (agent list failure must never focus)"
else
    assert_focus_not_called "explain must never call agent focus when 'herdr agent list' fails"
fi
teardown_test

# --- Scenario D: explain must report the SAME winner `next` actually picks --
# Non-obvious ordering: p_blocked1 falsely claimed P0 last yield and left
# without dispatching (false-claim demotion, §6.4) -- this state lives only
# in state.json, not in anything derivable from a single fresh `agent list`
# snapshot. A duplicated/stale copy of the cascade in explain.sh (one that
# doesn't consult the same state.json demotion bookkeeping the real
# schedule() path does) would report p_blocked1 as the still-P0 winner;
# the correct, non-duplicated implementation must report p_blocked2.
setup_test
stub_set_agent_list '[
  {"pane_id":"p_leave","agent_status":"working","state_change_seq":1,"tab_id":"t1","workspace_id":"ws1","cwd":"/repo","focused":true},
  {"pane_id":"p_blocked1","agent_status":"blocked","state_change_seq":2,"tab_id":"t1","workspace_id":"ws1","cwd":"/repo","focused":false},
  {"pane_id":"p_blocked2","agent_status":"blocked","state_change_seq":3,"tab_id":"t1","workspace_id":"ws1","cwd":"/repo","focused":false}
]'
stub_set_pane_read "p_blocked1" <<EOF
$CONFIRM_HINT_LINE
EOF
stub_set_pane_read "p_blocked2" <<EOF
$CONFIRM_HINT_LINE
EOF

invoke_status_changed "p_leave" "working"
rc=$?
if [ "$rc" -eq 127 ]; then
    fail_not_implemented "BASHAUMA_SCHEDULER_CMD (prerequisite dispatch yield for explain drift scenario)"
    teardown_test
    harness_report_and_exit
fi
assert_focus_called_with "p_blocked1" "prerequisite: first confirmed P0 (earlier seq) is picked initially"

# The user is now on p_blocked1 (still blocked, never dispatched) and
# presses `next`. This is the state whose winner explain must agree with.
stub_set_agent_list '[
  {"pane_id":"p_leave","agent_status":"working","state_change_seq":1,"tab_id":"t1","workspace_id":"ws1","cwd":"/repo","focused":false},
  {"pane_id":"p_blocked1","agent_status":"blocked","state_change_seq":2,"tab_id":"t1","workspace_id":"ws1","cwd":"/repo","focused":true},
  {"pane_id":"p_blocked2","agent_status":"blocked","state_change_seq":3,"tab_id":"t1","workspace_id":"ws1","cwd":"/repo","focused":false}
]'

# Clear the focus log recorded by the prerequisite dispatch above -- from
# here on, any focus call must be attributable to explain itself, not to
# setting up the scenario.
: >"$HERDR_STUB_DIR/focus_calls.log"

# Ask explain FIRST (must not perturb state or move focus), then invoke
# next for real and confirm the two agree.
invoke_explain "p_blocked1"
rc=$?
if [ "$rc" -eq 127 ]; then
    fail_not_implemented "BASHAUMA_EXPLAIN_CMD (winner must match real cascade, false-claim scenario)"
else
    assert_focus_not_called "explain must not have moved focus while reporting on the false-claim scenario"
    reported_winner=$(explain_winner_pane_id)
    assert_eq "$reported_winner" "p_blocked2" \
        "explain must report p_blocked2 as the winner -- p_blocked1's false-claim demotion lives only in state.json, so a duplicated/stale cascade copy would wrongly still favor p_blocked1"

    invoke_next "p_blocked1"
    assert_focus_called_with "p_blocked2" "next's real pick must match what explain reported"
    last_call=$(focus_calls | tail -n 1)
    assert_not_contains "$last_call" "p_blocked1" "p_blocked1 must not be re-picked as P0 immediately after its false claim"
fi
teardown_test

harness_report_and_exit
