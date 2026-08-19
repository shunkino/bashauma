#!/bin/bash
# REGRESSION — GitHub issue #1's more serious half is NOT actually fixed:
# a pane_id that already exists in `agent list` when schedule() FIRST
# observes it (i.e. no schedule() call ever ran while that ID was absent)
# inherits a stale p0_suppressed_pane_ids/demotion_count entry forever.
#
# Fenster's close-pruning fix (regression_close_reopen_pruning.sh) prunes
# suppression/demotion entries for IDs that are NOT in the live `agent
# list` set. That only removes an entry once schedule() runs while the
# pane is *actually absent*. But the failure mode issue #1 itself named as
# "the more serious half" is: herdr restarts, a workspace's pane_id
# counter resets, and a *brand-new* agent is allocated an ID that used to
# belong to a now-permanently-gone, previously-suppressed pane -- and
# state.json (a plain file, untouched by a herdr restart) still has that
# ID in p0_suppressed_pane_ids/demotion_count from before the restart.
#
# The critical detail: by construction, the very first schedule() call
# that could ever notice this is one where the recycled ID is ALREADY
# back in the live agent list (that's what "recycled" means -- there is
# no moment where schedule() sees it both closed AND about to be reused;
# it only ever sees it closed, or reused-and-already-open). The prune
# predicate is "keep this entry iff its ID is in the live set" -- which
# means a freshly-recycled, live ID is, definitionally, never pruned: it
# looks exactly like an ID that was never absent at all. So the fix
# genuinely resolves unbounded growth for IDs that stay closed, but does
# NOT resolve stale-inheritance for IDs that get reused, which is exactly
# the scenario the "more serious half" of issue #1 is about.
#
# Reproduced here without needing a real herdr restart: seed state.json
# with a suppressed/demotion record for a pane_id, then have that SAME
# pane_id appear, from the very first schedule() call, as a genuinely
# fresh, legitimately-blocked-and-P0-confirmable agent (indistinguishable,
# from bashauma's point of view, from "the ID got recycled after a
# restart"). Correct behavior per prd.md §6.2 (P0 before P1) would send
# focus to it immediately. Buggy (current) behavior treats it as still
# suppressed -- P1 -- and a lower-priority idle candidate wins instead,
# silently and permanently denying the genuinely-blocked agent the P0
# treatment it has never actually earned a demotion for.
#
# EXPECTED TO FAIL until the fix distinguishes "this ID is the same
# long-lived pane that was previously demoted" from "this ID is new/
# reused" -- e.g. by keying suppression on something that survives a
# restart less ambiguously, or by having bashauma itself detect and
# invalidate stale state on a herdr server restart (a herdr session/
# server-start identifier in state.json, checked at the top of
# schedule() and used to wipe stale entries wholesale, would close this
# properly; pruning against `agent list` alone cannot).
set -u
. "$(dirname "$0")/../lib/harness.sh"

setup_test

CONFIRM_HINT_LINE='│ ↑/↓ to select · enter to confirm · esc to cancel │'

# Simulates state.json surviving a herdr restart: p_recycled was
# suppressed by a *previous* agent that used to hold this pane_id.
seeded_state='{
  "epoch_fed_pane_ids": [],
  "pane_status": {},
  "first_runnable_at": {},
  "p0_demoted_pane_ids": [],
  "p0_suppressed_pane_ids": ["p_recycled"],
  "demotion_count": {"p_recycled": 3},
  "winner_fired_epoch": false,
  "last_winner_pane_id": null,
  "last_winner_was_p0": false
}'
printf '%s' "$seeded_state" >"$HERDR_PLUGIN_STATE_DIR/state.json"

# p_recycled is, from bashauma's perspective, brand new: it is genuinely
# blocked and its viewport genuinely confirms a P0 prompt. p_other is a
# harmless idle P1 candidate with a lower seq so it wins the P1 tiebreak
# if (bug) p_recycled gets forced into P1 instead of P0.
stub_set_agent_list '[
  {"pane_id":"p_leave","agent_status":"working","state_change_seq":1,"tab_id":"t1","workspace_id":"ws1","cwd":"/repo","focused":true},
  {"pane_id":"p_other","agent_status":"idle","state_change_seq":2,"tab_id":"t9","workspace_id":"ws9","cwd":"/elsewhere","focused":false},
  {"pane_id":"p_recycled","agent_status":"blocked","state_change_seq":3,"tab_id":"t9","workspace_id":"ws9","cwd":"/elsewhere","focused":false}
]'
stub_set_pane_read "p_recycled" <<EOF
$CONFIRM_HINT_LINE
EOF

invoke_status_changed "p_leave" "working"
rc=$?

if [ "$rc" -eq 127 ]; then
    fail_not_implemented "BASHAUMA_SCHEDULER_CMD (recycled-ID stale-suppression regression)"
else
    assert_focus_called_with "p_recycled" \
        "a genuinely blocked, P0-confirmed pane must win P0 even if its ID was suppressed by a *different*, now-gone agent before a herdr restart (issue #1's 'more serious half' -- close-pruning alone cannot fix this, since a recycled ID is never observed absent before it reappears)"
fi

teardown_test
harness_report_and_exit
