#!/bin/bash
# REGRESSION — prd.md §6.4 / GitHub issue #1: prune p0_suppressed_pane_ids
# and demotion_count when a pane closes.
#
# lib/scheduler.sh's close-pruning block (in schedule(), right after
# state_load()) now removes entries for pane IDs no longer present in
# `agent list`'s live set from ALL SIX maps -- previously only four were
# pruned (epoch_fed_pane_ids, pane_status, first_runnable_at,
# p0_demoted_pane_ids); p0_suppressed_pane_ids and demotion_count were
# left to grow forever.
#
# This case covers the literal scenario asked for in issue #1 and by
# Fenster: seed suppression/demotion state for two panes, then run a
# schedule() call where one of them has closed (dropped from `agent
# list`) and the other is still open. Assert the closed pane's entries
# are gone and the still-open pane's entries survive untouched.
#
# NOTE: this only proves the "unbounded growth" half of issue #1. It does
# NOT prove the "stale suppression survives an ID-reuse/herdr-restart"
# half -- see regression_id_recycle_suppression.sh for that (and read its
# header comment for why this test passing does not mean that one
# should).
set -u
. "$(dirname "$0")/../lib/harness.sh"

setup_test

seeded_state='{
  "epoch_fed_pane_ids": [],
  "pane_status": {},
  "first_runnable_at": {},
  "p0_demoted_pane_ids": [],
  "p0_suppressed_pane_ids": ["p_closed", "p_stays_open"],
  "demotion_count": {"p_closed": 3, "p_stays_open": 2},
  "winner_fired_epoch": false,
  "last_winner_pane_id": null,
  "last_winner_was_p0": false
}'
printf '%s' "$seeded_state" >"$HERDR_PLUGIN_STATE_DIR/state.json"

# p_closed has closed (not in agent list at all); p_stays_open is still
# open and idle (P1, harmless -- we only care what happens to its
# suppression/demotion bookkeeping, not whether it wins).
stub_set_agent_list '[
  {"pane_id":"p_stays_open","agent_status":"idle","state_change_seq":1,"tab_id":"t1","workspace_id":"ws1","cwd":"/repo","focused":true}
]'

invoke_next "p_stays_open"
rc=$?

if [ "$rc" -eq 127 ]; then
    fail_not_implemented "BASHAUMA_NEXT_CMD (close-pruning of p0_suppressed_pane_ids/demotion_count)"
else
    final_state=$(cat "$HERDR_PLUGIN_STATE_DIR/state.json")

    suppressed_has_closed=$(printf '%s' "$final_state" | jq -r '(.p0_suppressed_pane_ids // []) | index("p_closed") != null')
    assert_eq "$suppressed_has_closed" "false" \
        "p0_suppressed_pane_ids must drop a pane once it's closed (not in agent list)"

    suppressed_has_open=$(printf '%s' "$final_state" | jq -r '(.p0_suppressed_pane_ids // []) | index("p_stays_open") != null')
    assert_eq "$suppressed_has_open" "true" \
        "p0_suppressed_pane_ids must NOT drop a pane that is still open"

    demotion_has_closed=$(printf '%s' "$final_state" | jq -r '.demotion_count | has("p_closed")')
    assert_eq "$demotion_has_closed" "false" \
        "demotion_count must drop a pane once it's closed (not in agent list)"

    demotion_open_value=$(printf '%s' "$final_state" | jq -r '.demotion_count["p_stays_open"] // empty')
    assert_eq "$demotion_open_value" "2" \
        "demotion_count for a still-open pane must survive the prune unchanged"
fi

teardown_test
harness_report_and_exit
