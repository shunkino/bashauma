#!/bin/bash
# PRD §6.1 — Yield points.
#
# "Exactly two events cause bashauma to schedule: (1) a dispatch yield — a
# pane transitioning into `working`, and (2) an explicit yield — the `next`
# action." Both must move focus to the next runnable pane.
set -u
. "$(dirname "$0")/../lib/harness.sh"

# --- Scenario A: dispatch yield moves focus ---------------------------------
setup_test
stub_set_agent_list '[
  {"pane_id":"w1:p1","agent_status":"working","state_change_seq":1,"tab_id":"t1","workspace_id":"ws1","cwd":"/repo","focused":true},
  {"pane_id":"w1:p2","agent_status":"idle","state_change_seq":2,"tab_id":"t1","workspace_id":"ws1","cwd":"/repo","focused":false}
]'

invoke_status_changed "w1:p1" "working"
rc=$?

if [ "$rc" -eq 127 ]; then
    fail_not_implemented "BASHAUMA_SCHEDULER_CMD (dispatch yield / §6.1)"
else
    assert_focus_called_with "w1:p2" "dispatch yield moves focus to the only other runnable pane"
fi
teardown_test

# --- Scenario B: explicit `next` yield moves focus --------------------------
setup_test
stub_set_agent_list '[
  {"pane_id":"w1:p1","agent_status":"working","state_change_seq":1,"tab_id":"t1","workspace_id":"ws1","cwd":"/repo","focused":true},
  {"pane_id":"w1:p2","agent_status":"idle","state_change_seq":2,"tab_id":"t1","workspace_id":"ws1","cwd":"/repo","focused":false}
]'

invoke_next
rc=$?

if [ "$rc" -eq 127 ]; then
    fail_not_implemented "BASHAUMA_NEXT_CMD (explicit next yield / §6.1)"
else
    assert_focus_called_with "w1:p2" "explicit next yield moves focus to the only runnable pane"
fi
teardown_test

harness_report_and_exit
