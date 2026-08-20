#!/bin/bash
# v1.1 design (.squad/design/v1.1-scheduling.md, "B-lite -- one added
# lexicographic tier"): workspace-locality-when-idle. When nothing is
# blocked, prefer the agent in the workspace the user was already in (the
# departure pane's workspace_id). A HARD TIER inserted into the existing
# total order, NOT a weight:
#
#   aged_rank, class_rank, affinity_rank, workspace_locality_rank, seq, pane_id
#
# workspace_locality_rank = 0 if a candidate's workspace_id matches the
# departure pane's workspace_id, else 1.
#
# Design note worth stating explicitly (so a future reader isn't confused
# by why several of these scenarios use CONFIG_AFFINITY=none): under the
# DEFAULT affinity mode ("tab"), _affinity_rank's own tier 2 is already
# "same workspace_id as departure" -- so workspace_locality_rank, being
# compared strictly AFTER affinity_rank, can only ever matter among
# candidates ALREADY tied on affinity_rank, and two candidates tied at
# affinity_rank can never differ on "shares departure's workspace_id"
# (affinity_rank's own tiers already partition on exactly that). The new
# tier is therefore a *provable no-op* under "tab"/"workspace" affinity
# modes -- it only has an observable effect when affinity is disabled
# entirely (CONFIG_AFFINITY=none), which is also the one config surface
# through which this can be isolated and tested cleanly, independent of
# the pre-existing (and separately tested) affinity cascade. Scenario A
# below proves the no-op claim directly; scenarios B onward isolate the
# new tier's own behavior with affinity disabled.
#
# Written PROACTIVELY, ahead of Fenster's implementation.
set -u
. "$(dirname "$0")/../lib/harness.sh"

CONFIRM_HINT_LINE='│ ↑/↓ to select · enter to confirm · esc to cancel │'

# --- Scenario A: no-op under default affinity (regression guard) -----------
# Two P1 candidates tied at affinity_rank=3 ("other" -- neither shares
# tab/workspace/cwd with departure), and ALSO tied on workspace with each
# other (both different from departure, and different from each other) --
# the new tier must not change the existing FIFO tiebreak outcome here.
setup_test
stub_set_agent_list '[
  {"pane_id":"p_leave","agent_status":"working","state_change_seq":1,"tab_id":"t1","workspace_id":"ws1","cwd":"/repo","focused":true},
  {"pane_id":"p_later","agent_status":"idle","state_change_seq":9,"tab_id":"t9","workspace_id":"ws9","cwd":"/other9","focused":false},
  {"pane_id":"p_earlier","agent_status":"idle","state_change_seq":2,"tab_id":"t8","workspace_id":"ws8","cwd":"/other8","focused":false}
]'
invoke_status_changed "p_leave" "working"
rc=$?
if [ "$rc" -eq 127 ]; then
    fail_not_implemented "BASHAUMA_SCHEDULER_CMD (B-lite no-op under default affinity)"
else
    assert_focus_called_with "p_earlier" "under default (tab) affinity, workspace-locality must not change the pre-existing FIFO tiebreak outcome between two equally-distant candidates"
fi
teardown_test

# --- Scenario B: workspace-locality tier fires when affinity is disabled ---
setup_test
export BASHAUMA_AFFINITY=none
# p_same_ws shares departure's workspace (ws1) but not its tab; p_far is in
# a wholly different workspace. Seq numbers run AGAINST what a naive FIFO
# tiebreak would pick, so only the new tier explains a correct pick of
# p_same_ws.
stub_set_agent_list '[
  {"pane_id":"p_leave","agent_status":"working","state_change_seq":1,"tab_id":"t1","workspace_id":"ws1","cwd":"/repo","focused":true},
  {"pane_id":"p_far","agent_status":"idle","state_change_seq":5,"tab_id":"t9","workspace_id":"ws9","cwd":"/other","focused":false},
  {"pane_id":"p_same_ws","agent_status":"idle","state_change_seq":50,"tab_id":"t2","workspace_id":"ws1","cwd":"/different-cwd","focused":false}
]'
invoke_status_changed "p_leave" "working"
rc=$?
if [ "$rc" -eq 127 ]; then
    fail_not_implemented "BASHAUMA_SCHEDULER_CMD (B-lite workspace-locality tier, affinity=none)"
else
    assert_focus_called_with "p_same_ws" "with affinity disabled, workspace-locality-when-idle must still prefer the pane in the departure's workspace, even against a much older (lower-seq) candidate elsewhere"
fi
teardown_test
unset BASHAUMA_AFFINITY

# --- Scenario C: must NOT override P0 (a confirmed blocked pane still wins)
setup_test
export BASHAUMA_AFFINITY=none
# p_same_ws is idle, same workspace as departure. p_blocked_far is
# genuinely blocked, P0-confirmed, in a DIFFERENT workspace. class_rank is
# compared before workspace_locality_rank -- P0 must still win.
stub_set_agent_list '[
  {"pane_id":"p_leave","agent_status":"working","state_change_seq":1,"tab_id":"t1","workspace_id":"ws1","cwd":"/repo","focused":true},
  {"pane_id":"p_same_ws","agent_status":"idle","state_change_seq":2,"tab_id":"t2","workspace_id":"ws1","cwd":"/different-cwd","focused":false},
  {"pane_id":"p_blocked_far","agent_status":"blocked","state_change_seq":3,"tab_id":"t9","workspace_id":"ws9","cwd":"/other","focused":false}
]'
stub_set_pane_read "p_blocked_far" <<EOF
$CONFIRM_HINT_LINE
EOF
invoke_status_changed "p_leave" "working"
rc=$?
if [ "$rc" -eq 127 ]; then
    fail_not_implemented "BASHAUMA_SCHEDULER_CMD (B-lite must not override P0)"
else
    assert_focus_called_with "p_blocked_far" "a genuinely blocked, P0-confirmed pane in a DIFFERENT workspace must still win over a same-workspace idle P1 candidate -- workspace-locality is a same-class tiebreaker, it cannot cross the P0/P1 boundary"
fi
teardown_test
unset BASHAUMA_AFFINITY

# --- Scenario D: must NOT override aging promotion (starvation guarantee) ---
setup_test
export BASHAUMA_AFFINITY=none
export BASHAUMA_AGING_SECONDS_OVERRIDE=0
export BASHAUMA_AGING_SECONDS=0
stub_set_agent_list '[
  {"pane_id":"p_leave","agent_status":"working","state_change_seq":1,"tab_id":"t1","workspace_id":"ws1","cwd":"/repo","focused":true},
  {"pane_id":"p_hungry_far","agent_status":"idle","state_change_seq":2,"tab_id":"t9","workspace_id":"ws9","cwd":"/other","focused":false}
]'
# Seed p_hungry_far's queue-entry clock via a non-dispatch status change
# (must not move focus -- §6.5) before the real yield, then let it age out.
invoke_status_changed "p_hungry_far" "idle"
sleep 0.3

stub_set_agent_list '[
  {"pane_id":"p_leave","agent_status":"working","state_change_seq":1,"tab_id":"t1","workspace_id":"ws1","cwd":"/repo","focused":true},
  {"pane_id":"p_hungry_far","agent_status":"idle","state_change_seq":2,"tab_id":"t9","workspace_id":"ws9","cwd":"/other","focused":false},
  {"pane_id":"p_same_ws_fresh","agent_status":"idle","state_change_seq":3,"tab_id":"t2","workspace_id":"ws1","cwd":"/different-cwd","focused":false}
]'
invoke_status_changed "p_leave" "working"
rc=$?
if [ "$rc" -eq 127 ]; then
    fail_not_implemented "BASHAUMA_SCHEDULER_CMD (B-lite must not override aging promotion)"
else
    assert_focus_called_with "p_hungry_far" "an aged-out P1 candidate (starvation guarantee, §9 Band 1) must still win over a fresh same-workspace idle candidate -- workspace-locality cannot override aging"
    last_call=$(focus_calls | tail -n 1)
    assert_not_contains "$last_call" "p_same_ws_fresh" "the fresh same-workspace candidate must not be this yield's pick once p_hungry_far has aged past it"
fi
teardown_test
unset BASHAUMA_AFFINITY BASHAUMA_AGING_SECONDS_OVERRIDE BASHAUMA_AGING_SECONDS

# --- Scenario E: §6.4 determinism -- identical queue state, identical pick -
setup_test
export BASHAUMA_AFFINITY=none
stub_set_agent_list '[
  {"pane_id":"p_leave","agent_status":"working","state_change_seq":1,"tab_id":"t1","workspace_id":"ws1","cwd":"/repo","focused":true},
  {"pane_id":"p_far","agent_status":"idle","state_change_seq":5,"tab_id":"t9","workspace_id":"ws9","cwd":"/other","focused":false},
  {"pane_id":"p_same_ws","agent_status":"idle","state_change_seq":50,"tab_id":"t2","workspace_id":"ws1","cwd":"/different-cwd","focused":false}
]'
first_winner_run=1
expected_winner=""
for _ in 1 2 3; do
    printf '' >"$HERDR_STUB_DIR/focus_calls.log"
    invoke_status_changed "p_leave" "working" >/dev/null 2>&1
    rc=$?
    if [ "$rc" -eq 127 ]; then
        fail_not_implemented "BASHAUMA_SCHEDULER_CMD (B-lite determinism, repeated identical queue state)"
        first_winner_run=0
        break
    fi
    winner_this_run=$(focus_calls | tail -n 1)
    if [ "$first_winner_run" = "1" ]; then
        expected_winner="$winner_this_run"
        first_winner_run=0
    else
        assert_eq "$expected_winner" "$winner_this_run" "identical queue state must produce the identical pick every time, with the new tier in place"
    fi
done
teardown_test
unset BASHAUMA_AFFINITY

harness_report_and_exit
