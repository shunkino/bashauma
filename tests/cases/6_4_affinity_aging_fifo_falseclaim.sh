#!/bin/bash
# PRD §6.4 — Pick-next policy: affinity, aging, FIFO tiebreak, false-claim
# demotion.
#
# ASSUMPTION (flagged because the config wiring wasn't finalized when this
# was written): aging_seconds is assumed to be overridable via an
# environment variable, BASHAUMA_AGING_SECONDS, mirroring the existing
# BASHAUMA_DEBOUNCE_SECONDS / BASHAUMA_ACTIVITY_CHECK_SECONDS convention in
# on_status_changed.sh. If Fenster/Keaton wire config differently (e.g. a
# herdr-plugin.toml [config] block read some other way), scenario B below
# will need updating to seed the aging clock through the real mechanism.
# (Entrypoint file names and HERDR_PLUGIN_CONTEXT_JSON are no longer
# assumptions -- confirmed by Keaton, see
# .squad/decisions/inbox/keaton-v1-implementation-plan.md.)
set -u
. "$(dirname "$0")/../lib/harness.sh"

CONFIRM_HINT_LINE='│ ↑/↓ to select · enter to confirm · esc to cancel │'

# --- Scenario A: affinity ordering: same tab > same workspace > same cwd > other
setup_test
# Leaving pane: tab=t1, workspace=ws1, cwd=/repo.
# Seq numbers are chosen to run AGAINST FIFO order, so only affinity
# ordering explains a correct pick of p_tab.
stub_set_agent_list '[
  {"pane_id":"p_leave","agent_status":"working","state_change_seq":1,"tab_id":"t1","workspace_id":"ws1","cwd":"/repo","focused":true},
  {"pane_id":"p_other","agent_status":"idle","state_change_seq":70,"tab_id":"t9","workspace_id":"ws9","cwd":"/other","focused":false},
  {"pane_id":"p_cwd","agent_status":"idle","state_change_seq":80,"tab_id":"t9","workspace_id":"ws9","cwd":"/repo","focused":false},
  {"pane_id":"p_workspace","agent_status":"idle","state_change_seq":90,"tab_id":"t9","workspace_id":"ws1","cwd":"/diff","focused":false},
  {"pane_id":"p_tab","agent_status":"idle","state_change_seq":100,"tab_id":"t1","workspace_id":"ws1","cwd":"/repo","focused":false}
]'
invoke_status_changed "p_leave" "working"
rc=$?
if [ "$rc" -eq 127 ]; then
    fail_not_implemented "BASHAUMA_SCHEDULER_CMD (affinity ordering / §6.4)"
else
    assert_focus_called_with "p_tab" "same-tab affinity wins even against a much older (lower-seq) candidate"
fi
teardown_test

# --- Scenario B: aging promotes a stale P1 above P0 -------------------------
setup_test
export BASHAUMA_AGING_SECONDS_OVERRIDE=0
export BASHAUMA_AGING_SECONDS=0
stub_set_agent_list '[
  {"pane_id":"p_leave","agent_status":"working","state_change_seq":1,"tab_id":"t1","workspace_id":"ws1","cwd":"/repo","focused":true},
  {"pane_id":"p_hungry","agent_status":"idle","state_change_seq":2,"tab_id":"t9","workspace_id":"ws9","cwd":"/other","focused":false}
]'
# Seed the queue-entry timestamp for p_hungry with a non-dispatch status
# change (this must not move focus -- see §6.5) before the real yield.
invoke_status_changed "p_hungry" "idle"
sleep 0.3

stub_set_agent_list '[
  {"pane_id":"p_leave","agent_status":"working","state_change_seq":1,"tab_id":"t1","workspace_id":"ws1","cwd":"/repo","focused":true},
  {"pane_id":"p_hungry","agent_status":"idle","state_change_seq":2,"tab_id":"t9","workspace_id":"ws9","cwd":"/other","focused":false},
  {"pane_id":"p_blocked","agent_status":"blocked","state_change_seq":3,"tab_id":"t1","workspace_id":"ws1","cwd":"/repo","focused":false}
]'
stub_set_pane_read "p_blocked" <<EOF
$CONFIRM_HINT_LINE
EOF
invoke_status_changed "p_leave" "working"
rc=$?
if [ "$rc" -eq 127 ]; then
    fail_not_implemented "BASHAUMA_SCHEDULER_CMD (aging promotion / §6.4)"
else
    assert_focus_called_with "p_hungry" "aged-out P1 (wait > aging_seconds) is promoted above a confirmed P0"
    assert_not_contains "$(focus_calls | tail -n 1)" "p_blocked" "the confirmed P0 pane is NOT this yield's pick once p_hungry has aged past it"
fi
teardown_test

# --- Scenario C: FIFO tiebreak by state_change_seq --------------------------
setup_test
stub_set_agent_list '[
  {"pane_id":"p_leave","agent_status":"working","state_change_seq":1,"tab_id":"t1","workspace_id":"ws1","cwd":"/repo","focused":true},
  {"pane_id":"p_later","agent_status":"idle","state_change_seq":5,"tab_id":"t1","workspace_id":"ws1","cwd":"/repo","focused":false},
  {"pane_id":"p_earlier","agent_status":"idle","state_change_seq":2,"tab_id":"t1","workspace_id":"ws1","cwd":"/repo","focused":false}
]'
invoke_status_changed "p_leave" "working"
rc=$?
if [ "$rc" -eq 127 ]; then
    fail_not_implemented "BASHAUMA_SCHEDULER_CMD (FIFO tiebreak / §6.4)"
else
    assert_focus_called_with "p_earlier" "identical affinity: lower (earlier) state_change_seq wins the tie"
fi
teardown_test

# --- Scenario D: false-claim demotion ---------------------------------------
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
    fail_not_implemented "BASHAUMA_SCHEDULER_CMD (false-claim demotion / §6.4)"
else
    assert_focus_called_with "p_blocked1" "first confirmed P0 (earlier seq) is picked initially"

    # The user is now on p_blocked1 (still blocked -- they never dispatched
    # anything) and presses `next` to give up on it.
    stub_set_agent_list '[
      {"pane_id":"p_leave","agent_status":"working","state_change_seq":1,"tab_id":"t1","workspace_id":"ws1","cwd":"/repo","focused":false},
      {"pane_id":"p_blocked1","agent_status":"blocked","state_change_seq":2,"tab_id":"t1","workspace_id":"ws1","cwd":"/repo","focused":true},
      {"pane_id":"p_blocked2","agent_status":"blocked","state_change_seq":3,"tab_id":"t1","workspace_id":"ws1","cwd":"/repo","focused":false}
    ]'
    invoke_next
    assert_focus_called_with "p_blocked2" "false-claim demotion: p_blocked1 (left without dispatching) loses P0 status this epoch"
    last_call=$(focus_calls | tail -n 1)
    assert_not_contains "$last_call" "p_blocked1" "p_blocked1 must not be re-picked as P0 immediately after a false claim"
fi
teardown_test

harness_report_and_exit
