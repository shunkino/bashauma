#!/bin/bash
# REGRESSION GUARD — Keaton's state_change_seq lineage-verification fix for
# GitHub issue #1 (see .squad/decisions/inbox/keaton-id-recycle-fix.md,
# lib/scheduler.sh's _lineage_trusted()/_forget_stale_pane()) must not
# quietly disable the very feature it was protecting: a genuinely
# continuously-live, repeatedly-false-claiming pane must still reach
# p0_suppress_after_demotions and STAY suppressed, even though its own
# state_change_seq keeps moving forward (as it always legitimately will
# for a live agent). If ordinary seq progression during normal operation
# were ever treated as "not the same pane" (i.e. only a HIGHER observed
# seq than recorded could possibly be seen for a real, continuously-live
# pane -- a seq regression is the ONLY thing that should ever cost trust),
# suppression would become unreachable and a flapping-blocked agent could
# hog P0 forever in violation of prd.md's "repeated demotions... suppress
# its P0 eligibility entirely."
#
# This seeds demotion_count already at (threshold - 1) with a recorded
# demotion_seq baseline, drives one more genuine, in-episode false P0
# claim (pushing the pane over the p0_suppress_after_demotions default of
# 3 and recording a fresh demotion_seq), then -- in the SAME epoch, no
# restart, no ID reuse -- presents the SAME pane_id as genuinely
# P0-confirmable with a HIGHER (normally-advanced) state_change_seq.
# Correct behavior: the lineage check trusts the inherited suppression
# (observed seq >= recorded seq for a real live pane always holds), so
# the pane stays P1-suppressed and a lower-priority idle candidate wins
# instead.
set -u
. "$(dirname "$0")/../lib/harness.sh"

setup_test

CONFIRM_HINT_LINE='│ ↑/↓ to select · enter to confirm · esc to cancel │'
PLAIN_SCROLLBACK_LINE='$ some ordinary shell output, nothing to confirm here'

# --- seed: p_noisy already has 2 of the (default) 3 demotions on record,
# --- with a demotion_seq baseline recorded from its own prior life. ------
seeded_state='{
  "epoch_fed_pane_ids": [],
  "pane_status": {},
  "first_runnable_at": {},
  "p0_demoted_pane_ids": [],
  "p0_suppressed_pane_ids": [],
  "demotion_count": {"p_noisy": 2},
  "demotion_seq": {"p_noisy": 15},
  "winner_fired_epoch": false,
  "last_winner_pane_id": null,
  "last_winner_was_p0": false
}'
printf '%s' "$seeded_state" >"$HERDR_PLUGIN_STATE_DIR/state.json"

# --- round A: p_noisy is blocked again, seq advanced normally (20 >= 15),
# --- and genuinely fails P0 confirmation one more time -> should push
# --- demotion_count to 3 (the suppression threshold) and record
# --- demotion_seq=20. ------------------------------------------------------
stub_set_agent_list '[
  {"pane_id":"p_leave","agent_status":"working","state_change_seq":1,"tab_id":"t1","workspace_id":"ws1","cwd":"/repo","focused":true},
  {"pane_id":"p_noisy","agent_status":"blocked","state_change_seq":20,"tab_id":"t9","workspace_id":"ws9","cwd":"/elsewhere","focused":false}
]'
stub_set_pane_read "p_noisy" <<EOF
$PLAIN_SCROLLBACK_LINE
EOF

invoke_status_changed "p_leave" "working"
rc=$?

if [ "$rc" -eq 127 ]; then
    fail_not_implemented "BASHAUMA_SCHEDULER_CMD (suppression-survives-lineage-check regression, round A)"
    teardown_test
    harness_report_and_exit
fi

demotion_count_after_a=$(jq -r '.demotion_count.p_noisy // 0' "$HERDR_PLUGIN_STATE_DIR/state.json")
suppressed_after_a=$(jq -r '(.p0_suppressed_pane_ids // []) | index("p_noisy") != null' "$HERDR_PLUGIN_STATE_DIR/state.json")
assert_eq "3" "$demotion_count_after_a" \
    "round A: p_noisy's 3rd genuine false P0 claim in its own continuous life should push demotion_count to the p0_suppress_after_demotions threshold (3)"
assert_eq "true" "$suppressed_after_a" \
    "round A: reaching the suppression threshold should add p_noisy to p0_suppressed_pane_ids"

# --- round B: SAME epoch, SAME pane_id, no restart, no ID reuse. p_noisy
# --- is now genuinely P0-confirmable (a real prompt appeared), and its
# --- seq has advanced further (30 >= 20) exactly as it always would for
# --- a real continuously-live agent. p_other is a harmless idle P1
# --- candidate with a lower seq: if (bug) the lineage check spuriously
# --- "forgives" p_noisy here and elevates it to P0, p_noisy wins; if
# --- suppression correctly persists, p_noisy stays P1 and p_other (lower
# --- seq, FIFO tiebreak) wins instead. ------------------------------------
stub_set_agent_list '[
  {"pane_id":"p_leave","agent_status":"working","state_change_seq":1,"tab_id":"t1","workspace_id":"ws1","cwd":"/repo","focused":true},
  {"pane_id":"p_other","agent_status":"idle","state_change_seq":5,"tab_id":"t9","workspace_id":"ws9","cwd":"/elsewhere","focused":false},
  {"pane_id":"p_noisy","agent_status":"blocked","state_change_seq":30,"tab_id":"t9","workspace_id":"ws9","cwd":"/elsewhere","focused":false}
]'
stub_set_pane_read "p_noisy" <<EOF
$CONFIRM_HINT_LINE
EOF

invoke_status_changed "p_leave" "working"
rc=$?

if [ "$rc" -eq 127 ]; then
    fail_not_implemented "BASHAUMA_SCHEDULER_CMD (suppression-survives-lineage-check regression, round B)"
else
    assert_focus_called_with "p_other" \
        "a pane already suppressed within its own continuous life must STAY suppressed when its state_change_seq advances normally (no regression) -- ordinary seq movement must never be treated as evidence of a different pane, or p0_suppress_after_demotions becomes unreachable"
    suppressed_after_b=$(jq -r '(.p0_suppressed_pane_ids // []) | index("p_noisy") != null' "$HERDR_PLUGIN_STATE_DIR/state.json")
    assert_eq "true" "$suppressed_after_b" \
        "round B: p_noisy's suppression record must not be wiped by _forget_stale_pane when lineage is genuinely trusted (seq only advanced, never regressed)"
fi

teardown_test
harness_report_and_exit
