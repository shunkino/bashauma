#!/bin/bash
# PRD §6.2 — Ready queue and priority classes.
#
#   - P0 (blocked, confirmed) must be picked before P1 (idle/done).
#   - A `blocked` candidate that FAILS the bottom-anchored confirmation check
#     is demoted to P1 for the epoch, not treated as P0.
#   - A `blocked` candidate that PASSES confirmation stays P0.
set -u
. "$(dirname "$0")/../lib/harness.sh"

CONFIRM_HINT_LINE='│ ↑/↓ to select · enter to confirm · esc to cancel │'

# --- Scenario A: P0 (confirmed blocked) is picked before P1 (idle) ----------
setup_test
stub_set_agent_list '[
  {"pane_id":"w1:leaving","agent_status":"working","state_change_seq":1,"tab_id":"t1","workspace_id":"ws1","cwd":"/repo","focused":true},
  {"pane_id":"w1:idle","agent_status":"idle","state_change_seq":2,"tab_id":"t9","workspace_id":"ws9","cwd":"/elsewhere","focused":false},
  {"pane_id":"w1:blocked","agent_status":"blocked","state_change_seq":3,"tab_id":"t9","workspace_id":"ws9","cwd":"/elsewhere","focused":false}
]'
stub_set_pane_read "w1:blocked" <<EOF
some earlier agent output
$CONFIRM_HINT_LINE
EOF

invoke_status_changed "w1:leaving" "working"
rc=$?
if [ "$rc" -eq 127 ]; then
    fail_not_implemented "BASHAUMA_SCHEDULER_CMD (P0 before P1 / §6.2)"
else
    assert_focus_called_with "w1:blocked" "confirmed P0 (blocked) beats P1 (idle) even without affinity"
    assert_focus_call_count 1 "exactly one focus move per yield"
fi
teardown_test

# --- Scenario B: blocked candidate FAILS bottom confirmation -> demoted -----
# Confirmation phrases only appear far above the bottom N non-empty lines,
# so the candidate must be treated as P1, and since the only other pane is
# idle (also P1), affinity/FIFO decide — but the key assertion is that the
# scheduler does NOT treat the unconfirmed blocked pane as automatically
# correct; here we make the unconfirmed candidate's affinity strictly worse
# so a P0-first bug would still visibly pick the wrong (blocked) pane.
setup_test
stub_set_agent_list '[
  {"pane_id":"w1:leaving","agent_status":"working","state_change_seq":1,"tab_id":"t1","workspace_id":"ws1","cwd":"/repo","focused":true},
  {"pane_id":"w1:idle-near","agent_status":"idle","state_change_seq":2,"tab_id":"t1","workspace_id":"ws1","cwd":"/repo","focused":false},
  {"pane_id":"w1:blocked-unconfirmed","agent_status":"blocked","state_change_seq":3,"tab_id":"t9","workspace_id":"ws9","cwd":"/elsewhere","focused":false}
]'
# No prompt-hint phrases anywhere -> confirmation fails outright.
stub_set_pane_read "w1:blocked-unconfirmed" <<EOF
just some regular scrollback
nothing prompt-like here
EOF

invoke_status_changed "w1:leaving" "working"
rc=$?
if [ "$rc" -eq 127 ]; then
    fail_not_implemented "BASHAUMA_SCHEDULER_CMD (blocked_confirm demotion / §6.2)"
else
    assert_focus_called_with "w1:idle-near" "unconfirmed blocked candidate is demoted to P1 and loses to same-tab P1 affinity"
    assert_not_contains "$(focus_calls)" "w1:blocked-unconfirmed" "unconfirmed blocked candidate must never receive focus as P0"
fi
teardown_test

# --- Scenario C: blocked candidate PASSES bottom confirmation -> stays P0 ---
setup_test
stub_set_agent_list '[
  {"pane_id":"w1:leaving","agent_status":"working","state_change_seq":1,"tab_id":"t1","workspace_id":"ws1","cwd":"/repo","focused":true},
  {"pane_id":"w1:idle-near","agent_status":"idle","state_change_seq":2,"tab_id":"t1","workspace_id":"ws1","cwd":"/repo","focused":false},
  {"pane_id":"w1:blocked-confirmed","agent_status":"blocked","state_change_seq":3,"tab_id":"t9","workspace_id":"ws9","cwd":"/elsewhere","focused":false}
]'
stub_set_pane_read "w1:blocked-confirmed" <<EOF
$CONFIRM_HINT_LINE
EOF

invoke_status_changed "w1:leaving" "working"
rc=$?
if [ "$rc" -eq 127 ]; then
    fail_not_implemented "BASHAUMA_SCHEDULER_CMD (confirmed blocked stays P0 / §6.2)"
else
    assert_focus_called_with "w1:blocked-confirmed" "confirmed blocked candidate stays P0 even against closer-affinity P1"
fi
teardown_test

harness_report_and_exit
