#!/bin/bash
# PRD §6.8 — Configuration.
#
# ASSUMPTION (flagged, config wiring not finalized at time of writing):
# config keys are assumed surfaced as environment variables following the
# existing BASHAUMA_* convention already used for debounce/activity timing
# in on_status_changed.sh:
#   BASHAUMA_MODE            <- `mode`            ("on" | "off")
#   BASHAUMA_PARKED_PANES    <- `parked_panes`     (comma-separated pane ids)
#   BASHAUMA_BLOCKED_CONFIRM <- `blocked_confirm`  ("true" | "false")
# If Fenster/Keaton wire config another way (e.g. a JSON blob, or reading
# herdr-plugin.toml directly), update the exports below to match -- the
# assertions themselves should still hold. (Entrypoint file names and the
# HERDR_PLUGIN_CONTEXT_JSON departure-pane context are no longer
# assumptions -- confirmed by Keaton, see
# .squad/decisions/inbox/keaton-v1-implementation-plan.md.)
set -u
. "$(dirname "$0")/../lib/harness.sh"

# --- Scenario A: mode = off disables scheduling but `next` still works -----
setup_test
export BASHAUMA_MODE=off
stub_set_agent_list '[
  {"pane_id":"p_leave","agent_status":"working","state_change_seq":1,"tab_id":"t1","workspace_id":"ws1","cwd":"/repo","focused":true},
  {"pane_id":"p_other","agent_status":"idle","state_change_seq":2,"tab_id":"t1","workspace_id":"ws1","cwd":"/repo","focused":false}
]'

invoke_status_changed "p_leave" "working"
rc=$?
if [ "$rc" -eq 127 ]; then
    fail_not_implemented "BASHAUMA_SCHEDULER_CMD (mode=off / §6.8)"
else
    assert_focus_not_called "mode=off: a dispatch does not trigger automatic scheduling"
fi

invoke_next
rc=$?
if [ "$rc" -eq 127 ]; then
    fail_not_implemented "BASHAUMA_NEXT_CMD (mode=off, next still works / §6.8)"
else
    assert_focus_called_with "p_other" "mode=off: the explicit next action still works"
fi
unset BASHAUMA_MODE
teardown_test

# --- Scenario B: parked_panes excluded from the runnable set ---------------
setup_test
export BASHAUMA_PARKED_PANES="p_parked"
stub_set_agent_list '[
  {"pane_id":"p_leave","agent_status":"working","state_change_seq":1,"tab_id":"t1","workspace_id":"ws1","cwd":"/repo","focused":true},
  {"pane_id":"p_parked","agent_status":"idle","state_change_seq":2,"tab_id":"t1","workspace_id":"ws1","cwd":"/repo","focused":false},
  {"pane_id":"p_normal","agent_status":"idle","state_change_seq":3,"tab_id":"t9","workspace_id":"ws9","cwd":"/other","focused":false}
]'

invoke_status_changed "p_leave" "working"
rc=$?
if [ "$rc" -eq 127 ]; then
    fail_not_implemented "BASHAUMA_SCHEDULER_CMD (parked_panes / §6.8)"
else
    assert_focus_called_with "p_normal" "parked_panes: falls through to the non-parked candidate"
    assert_not_contains "$(focus_calls)" "p_parked" "parked_panes: a parked pane is never focused, even with better affinity"
fi
unset BASHAUMA_PARKED_PANES
teardown_test

# --- Scenario C: blocked_confirm = false trusts herdr verbatim -------------
setup_test
export BASHAUMA_BLOCKED_CONFIRM=false
stub_set_agent_list '[
  {"pane_id":"p_leave","agent_status":"working","state_change_seq":1,"tab_id":"t1","workspace_id":"ws1","cwd":"/repo","focused":true},
  {"pane_id":"p_blocked_unconfirmed","agent_status":"blocked","state_change_seq":2,"tab_id":"t9","workspace_id":"ws9","cwd":"/other","focused":false}
]'
# Deliberately no pane_read fixture (or non-matching content) -- with
# blocked_confirm=true this would fail confirmation and demote to P1.
stub_set_pane_read "p_blocked_unconfirmed" <<'EOF'
nothing prompt-like here at all
EOF

invoke_status_changed "p_leave" "working"
rc=$?
if [ "$rc" -eq 127 ]; then
    fail_not_implemented "BASHAUMA_SCHEDULER_CMD (blocked_confirm=false / §6.8)"
else
    assert_focus_called_with "p_blocked_unconfirmed" "blocked_confirm=false: herdr's blocked verdict is trusted verbatim, no bottom-line check"
fi
unset BASHAUMA_BLOCKED_CONFIRM
teardown_test

harness_report_and_exit
