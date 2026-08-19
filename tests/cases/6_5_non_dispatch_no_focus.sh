#!/bin/bash
# PRD §6.5 / §9 — non-dispatch status changes must NEVER move focus.
#
# "working → idle, working → done, and working → blocked do not move focus.
# They only change which class the pane will fall into at the next yield."
#
# §9 calls this a HARD INVARIANT, not a target: "focus never moves except at
# a yield point." This is the single most important test in the suite —
# it is exactly the v0.1 "finish-focus" bug this revision removes.
set -u
. "$(dirname "$0")/../lib/harness.sh"

check_no_focus_on_transition() { # $1 pane_id, $2 from_status (for fixture realism), $3 to_status
    local pane_id="$1" to_status="$3"
    setup_test
    stub_set_agent_list "[
      {\"pane_id\":\"$pane_id\",\"agent_status\":\"$to_status\",\"state_change_seq\":1,\"tab_id\":\"t1\",\"workspace_id\":\"ws1\",\"cwd\":\"/repo\",\"focused\":true},
      {\"pane_id\":\"w1:other\",\"agent_status\":\"idle\",\"state_change_seq\":2,\"tab_id\":\"t2\",\"workspace_id\":\"ws2\",\"cwd\":\"/elsewhere\",\"focused\":false}
    ]"
    invoke_status_changed "$pane_id" "$to_status"
    rc=$?
    if [ "$rc" -eq 127 ]; then
        fail_not_implemented "BASHAUMA_SCHEDULER_CMD (non-dispatch status change / §6.5)"
    else
        assert_focus_not_called "working -> $to_status must not move focus (hard invariant, §9)"
    fi
    teardown_test
}

check_no_focus_on_transition "w1:p1" "working" "idle"
check_no_focus_on_transition "w1:p2" "working" "done"
check_no_focus_on_transition "w1:p3" "working" "blocked"

harness_report_and_exit
