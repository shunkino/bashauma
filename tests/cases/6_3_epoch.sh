#!/bin/bash
# PRD §6.3 — Epochs.
#
#   - A pane is "fed" for the epoch once dispatched; fed panes are excluded
#     from the runnable set for the rest of the epoch even if their status
#     later changes (e.g. finishes and goes idle again before the epoch
#     ends) — fed only clears when the epoch resets.
#   - Closed panes are dropped from the fed set so a fed-then-closed pane
#     can't wedge an epoch that would otherwise complete.
#   - An epoch ends (winner screen fires) when the runnable set is empty:
#     every open pane is working or fed, and nothing is blocked. Fires at
#     most once per epoch.
set -u
. "$(dirname "$0")/../lib/harness.sh"

# --- Scenario A: fed panes skipped across an epoch; winner fires once ------
setup_test

# p1 is already mid-dispatch (the pane the user is leaving); p2, p3 are the
# two hungry candidates, FIFO ordered by state_change_seq.
stub_set_agent_list '[
  {"pane_id":"p1","agent_status":"working","state_change_seq":1,"tab_id":"t1","workspace_id":"ws1","cwd":"/repo","focused":true},
  {"pane_id":"p2","agent_status":"idle","state_change_seq":2,"tab_id":"t1","workspace_id":"ws1","cwd":"/repo","focused":false},
  {"pane_id":"p3","agent_status":"idle","state_change_seq":3,"tab_id":"t1","workspace_id":"ws1","cwd":"/repo","focused":false}
]'
invoke_status_changed "p1" "working"
rc1=$?

if [ "$rc1" -eq 127 ]; then
    fail_not_implemented "BASHAUMA_SCHEDULER_CMD (epoch tracking / §6.3)"
else
    assert_focus_called_with "p2" "first dispatch (p1) hands off to earliest hungry pane (p2)"

    # User dispatches to p2. Now fed = {p1, p2}; only p3 is runnable.
    stub_set_agent_list '[
      {"pane_id":"p1","agent_status":"working","state_change_seq":1,"tab_id":"t1","workspace_id":"ws1","cwd":"/repo","focused":false},
      {"pane_id":"p2","agent_status":"working","state_change_seq":2,"tab_id":"t1","workspace_id":"ws1","cwd":"/repo","focused":true},
      {"pane_id":"p3","agent_status":"idle","state_change_seq":3,"tab_id":"t1","workspace_id":"ws1","cwd":"/repo","focused":false}
    ]'
    invoke_status_changed "p2" "working"
    assert_focus_called_with "p3" "second dispatch (p2) hands off to the remaining hungry pane (p3)"
    assert_focus_call_count 2 "still only two real yields so far"

    # p2 finishes and reverts to idle mid-epoch (a non-dispatch transition,
    # must not move focus per §6.5) -- and, critically, must NOT make p2
    # eligible to be picked again this epoch; it stays fed until the epoch
    # resets.
    calls_before=$(focus_call_count)
    stub_set_agent_list '[
      {"pane_id":"p1","agent_status":"working","state_change_seq":1,"tab_id":"t1","workspace_id":"ws1","cwd":"/repo","focused":false},
      {"pane_id":"p2","agent_status":"idle","state_change_seq":2,"tab_id":"t1","workspace_id":"ws1","cwd":"/repo","focused":true},
      {"pane_id":"p3","agent_status":"idle","state_change_seq":3,"tab_id":"t1","workspace_id":"ws1","cwd":"/repo","focused":false}
    ]'
    invoke_status_changed "p2" "idle"
    calls_after=$(focus_call_count)
    assert_eq "$calls_after" "$calls_before" "p2 reverting to idle mid-epoch is not a yield: no new focus call"

    # User dispatches p3 -> working. p2 is still idle in agent_list but was
    # already fed this epoch, so the runnable set is now empty (p1 working,
    # p2 fed, p3 working/fed) -> epoch drains -> winner screen fires exactly
    # once, and nothing new is focused (nowhere runnable to send the user).
    stub_set_agent_list '[
      {"pane_id":"p1","agent_status":"working","state_change_seq":1,"tab_id":"t1","workspace_id":"ws1","cwd":"/repo","focused":false},
      {"pane_id":"p2","agent_status":"idle","state_change_seq":2,"tab_id":"t1","workspace_id":"ws1","cwd":"/repo","focused":false},
      {"pane_id":"p3","agent_status":"working","state_change_seq":3,"tab_id":"t1","workspace_id":"ws1","cwd":"/repo","focused":true}
    ]'
    invoke_status_changed "p3" "working"
    assert_focus_call_count 2 "epoch drain does not focus anywhere (fed p2 is correctly excluded despite being idle)"
    assert_winner_fired_count 1 "winner screen fires exactly once when the (fed-aware) runnable set empties"
fi
teardown_test

# --- Scenario B: a fed-then-closed pane cannot wedge the epoch -------------
setup_test
stub_set_agent_list '[
  {"pane_id":"p1","agent_status":"working","state_change_seq":1,"tab_id":"t1","workspace_id":"ws1","cwd":"/repo","focused":true},
  {"pane_id":"p2","agent_status":"idle","state_change_seq":2,"tab_id":"t1","workspace_id":"ws1","cwd":"/repo","focused":false},
  {"pane_id":"p3","agent_status":"idle","state_change_seq":3,"tab_id":"t1","workspace_id":"ws1","cwd":"/repo","focused":false}
]'
invoke_status_changed "p1" "working"
rc2=$?
if [ "$rc2" -eq 127 ]; then
    fail_not_implemented "BASHAUMA_SCHEDULER_CMD (closed pane fed-set pruning / §6.3)"
else
    assert_focus_called_with "p2" "hands off to p2 first"

    # p1 (already fed) is now closed entirely -- dropped from the open set.
    # No status-changed event fires for a close; only the next agent list
    # snapshot changes.
    stub_set_agent_list '[
      {"pane_id":"p2","agent_status":"working","state_change_seq":2,"tab_id":"t1","workspace_id":"ws1","cwd":"/repo","focused":true},
      {"pane_id":"p3","agent_status":"idle","state_change_seq":3,"tab_id":"t1","workspace_id":"ws1","cwd":"/repo","focused":false}
    ]'
    invoke_status_changed "p2" "working"
    assert_focus_called_with "p3" "hands off to the last remaining hungry pane"

    # Dispatch p3. p1 no longer exists anywhere; if its stale fed entry were
    # not pruned on close, a naive "len(fed) == len(open)" check could
    # mismatch (3 vs 2) and wedge the epoch open forever. It must still
    # drain and fire the winner screen.
    stub_set_agent_list '[
      {"pane_id":"p2","agent_status":"working","state_change_seq":2,"tab_id":"t1","workspace_id":"ws1","cwd":"/repo","focused":false},
      {"pane_id":"p3","agent_status":"working","state_change_seq":3,"tab_id":"t1","workspace_id":"ws1","cwd":"/repo","focused":true}
    ]'
    invoke_status_changed "p3" "working"
    assert_winner_fired_count 1 "epoch drains and fires exactly once even though a fed pane (p1) closed mid-epoch"
fi
teardown_test

harness_report_and_exit
