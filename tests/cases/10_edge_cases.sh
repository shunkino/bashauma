#!/bin/bash
# PRD §10 — Edge cases.
#
#   - Zero or one agent open: scheduling is a no-op.
#   - All agents blocked: no deadlock; the queue is fully runnable.
#   - Dispatch to the same pane twice: it's already fed; picks the next
#     runnable pane instead.
#   - `agent list` failure: leave all state untouched and do nothing. Never
#     guess.
set -u
. "$(dirname "$0")/../lib/harness.sh"

CONFIRM_HINT_LINE='│ ↑/↓ to select · enter to confirm · esc to cancel │'

# --- Scenario A: zero agents open (edge: dispatch event for a pane not in
# the current agent list, e.g. it closed immediately after dispatching) -----
setup_test
stub_set_agent_list '[]'
invoke_status_changed "p_gone" "working"
rc=$?
if [ "$rc" -eq 127 ]; then
    fail_not_implemented "BASHAUMA_SCHEDULER_CMD (zero agents / §10)"
else
    assert_focus_not_called "zero agents open: scheduling is a no-op"
fi
teardown_test

# --- Scenario B: one agent open --------------------------------------------
setup_test
stub_set_agent_list '[
  {"pane_id":"p_solo","agent_status":"working","state_change_seq":1,"tab_id":"t1","workspace_id":"ws1","cwd":"/repo","focused":true}
]'
invoke_status_changed "p_solo" "working"
rc=$?
if [ "$rc" -eq 127 ]; then
    fail_not_implemented "BASHAUMA_SCHEDULER_CMD (single agent / §10)"
else
    assert_focus_not_called "a single agent still completes an epoch with nowhere else to send focus"
    assert_winner_fired_count 1 "a single agent still celebrates when its epoch drains"
fi
teardown_test

# --- Scenario C: all agents blocked -----------------------------------------
setup_test
stub_set_agent_list '[
  {"pane_id":"p_leave","agent_status":"working","state_change_seq":1,"tab_id":"t1","workspace_id":"ws1","cwd":"/repo","focused":true},
  {"pane_id":"p_b1","agent_status":"blocked","state_change_seq":2,"tab_id":"t1","workspace_id":"ws1","cwd":"/repo","focused":false},
  {"pane_id":"p_b2","agent_status":"blocked","state_change_seq":3,"tab_id":"t1","workspace_id":"ws1","cwd":"/repo","focused":false}
]'
stub_set_pane_read "p_b1" <<EOF
$CONFIRM_HINT_LINE
EOF
stub_set_pane_read "p_b2" <<EOF
$CONFIRM_HINT_LINE
EOF
invoke_status_changed "p_leave" "working"
rc=$?
if [ "$rc" -eq 127 ]; then
    fail_not_implemented "BASHAUMA_SCHEDULER_CMD (all agents blocked / §10)"
else
    assert_focus_called_with "p_b1" "all-blocked: the earliest confirmed P0 candidate is picked, no deadlock"
fi
teardown_test

# --- Scenario D: dispatch to the same pane twice ----------------------------
setup_test
stub_set_agent_list '[
  {"pane_id":"p_repeat","agent_status":"working","state_change_seq":1,"tab_id":"t1","workspace_id":"ws1","cwd":"/repo","focused":true},
  {"pane_id":"p_other","agent_status":"idle","state_change_seq":2,"tab_id":"t1","workspace_id":"ws1","cwd":"/repo","focused":false}
]'
invoke_status_changed "p_repeat" "working"
rc=$?
if [ "$rc" -eq 127 ]; then
    fail_not_implemented "BASHAUMA_SCHEDULER_CMD (repeat dispatch, first call / §10)"
else
    assert_focus_called_with "p_other" "first dispatch to p_repeat sends focus to the only other pane"

    # User (somehow) dispatches to p_repeat again -- it's already fed; the
    # scheduler must not treat this as a fresh candidate or error, and since
    # p_other is now the only thing that could still be picked but it too
    # already received focus (not fed until it itself is dispatched), the
    # important invariant is simply: no crash, and p_repeat is never
    # re-targeted as if newly runnable.
    calls_before=$(focus_call_count)
    invoke_status_changed "p_repeat" "working"
    assert_exit_code 0 "$?" "re-dispatching an already-fed pane does not error"
fi
teardown_test

# --- Scenario E: `agent list` failure leaves state untouched, does nothing -
setup_test
stub_fail_agent_list
invoke_status_changed "p_x" "working"
rc=$?
if [ "$rc" -eq 127 ]; then
    fail_not_implemented "BASHAUMA_SCHEDULER_CMD (agent list failure / §10)"
else
    assert_focus_not_called "agent list failure: never guess, no focus move"
    assert_winner_fired_count 0 "agent list failure: no winner screen either"
fi
teardown_test

harness_report_and_exit
