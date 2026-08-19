#!/bin/bash
# PRD §6.6 — Flicker filtering.
#
# "Every dispatch detection is debounced (~1.5s) and re-verified with
# `agent get` before being treated as a yield." A status flip that reverts
# within the debounce window (e.g. Copilot CLI's tasks sub-view opening and
# closing) must NOT count as a dispatch yield -- no focus move.
set -u
. "$(dirname "$0")/../lib/harness.sh"

setup_test
# Use a real, short debounce window so the test asserts genuine debounce
# behavior rather than a stubbed-out zero-wait.
export BASHAUMA_DEBOUNCE_SECONDS=0.3

stub_set_agent_list '[
  {"pane_id":"p_flicker","agent_status":"working","state_change_seq":1,"tab_id":"t1","workspace_id":"ws1","cwd":"/repo","focused":true},
  {"pane_id":"p_other","agent_status":"idle","state_change_seq":2,"tab_id":"t1","workspace_id":"ws1","cwd":"/repo","focused":false}
]'
# The re-verification `agent get` call (after the debounce sleep) reports
# the pane has flickered back to its pre-flicker status ("idle"), i.e. it
# was never really dispatched.
stub_set_agent_get "p_flicker" '{"pane_id":"p_flicker","agent_status":"idle","state_change_seq":1,"tab_id":"t1","workspace_id":"ws1","cwd":"/repo","focused":true}'

invoke_status_changed "p_flicker" "working"
rc=$?
if [ "$rc" -eq 127 ]; then
    fail_not_implemented "BASHAUMA_SCHEDULER_CMD (flicker debounce / §6.6)"
else
    assert_focus_not_called "a status flip that reverts within the debounce window is not treated as a dispatch yield"
fi
teardown_test

harness_report_and_exit
