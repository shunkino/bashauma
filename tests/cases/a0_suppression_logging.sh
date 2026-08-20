#!/bin/bash
# v1.1 design (.squad/design/v1.1-scheduling.md, "Revised recommended
# order" item 2 -- "A-0 -- suppression logging only"): NO behavior change,
# no config surface, no state schema change. Log every time a pane's
# demotion_count crosses p0_suppress_after_demotions (entry into
# suppression) and every time a suppressed pane is close-pruned, to the
# same stderr channel already established for config-warning visibility
# (herdr plugin log list --plugin bashauma; see
# .squad/decisions.md 2026-08-19T21:36:10). Written PROACTIVELY, ahead of
# Fenster's implementation.
#
# Exact message wording isn't pinned by the design doc, so this test
# checks for the pane_id and the log line's distinctive SHAPE (a fixed
# prefix + "crossed P0 suppression threshold" / "pruned on close") on
# stderr specifically, rather than a bare "suppress" keyword anywhere in
# the fused stdout+stderr stream -- unlike regression_config_warning.sh,
# which could assert verbatim text because issue #2's fix already
# specified the exact message. If Fenster lands genuinely different
# wording for the real log line, only the needle strings below need
# updating, not the intent of the assertions.
#
# --- Why stderr-only, and why a distinctive needle, not a bare keyword ---
# (2026-08-20 correction, Hockney review follow-up.) The original version
# of this file asserted `assert_not_contains "$HARNESS_LAST_OUTPUT"
# "suppress"` against the FUSED stdout+stderr stream. That was too broad:
# `explain`'s real, legitimate stdout report is *supposed* to discuss
# suppression by name -- it prints the `p0_suppress_after_demotions`
# config key and a per-candidate `suppressed=` field, both correct,
# useful diagnostic output whose whole job is explaining suppression
# state. A bare keyword check against the fused stream can't distinguish
# "explain's report legitimately mentions suppression" from "A-0's real
# threshold-crossing log fired" -- so it drove a bad fix (relabeling the
# report's own field names to dodge the substring, which would have left
# `explain` printing a config key, `p0_supp_after_demotions`, that
# doesn't match the real key in config.json -- a usability regression,
# not a real fix). The property actually worth pinning is narrow: A-0's
# specific, persisted-event log line (identified by its distinctive
# prefix, not by the word "suppress" in isolation) must not fire from a
# call that never persists anything. So Scenarios C and D below assert
# against $HARNESS_LAST_STDERR only, matching the real log line's
# distinctive shape ("crossed P0 suppression threshold" / "pruned on
# close"), leaving explain's stdout report free to discuss suppression
# as much as it needs to. Scenarios A and B (which assert the log DOES
# fire) are updated the same way for consistency, even though their
# broader needle wasn't the one that broke -- keeping all four scenarios
# on the same, more precise convention avoids the same fragility
# resurfacing here later.
#
# The single most important property here (explicitly named in the task):
# a log that cries wolf is useless as evidence. A-0's entire purpose is to
# be trustworthy input to a future decision about whether to build full
# demotion decay (A-full) -- so "does NOT fire spuriously during ordinary
# operation" is tested as rigorously as "does fire on the real events".
set -u
. "$(dirname "$0")/../lib/harness.sh"

CONFIRM_HINT_LINE='│ ↑/↓ to select · enter to confirm · esc to cancel │'
PLAIN_SCROLLBACK_LINE='$ ordinary shell output, nothing to confirm here'

# --- Scenario A: threshold-crossing fires a log line ------------------------
# Seed demotion_count already at (threshold - 1) with a recorded
# demotion_seq baseline (same seeding shape as
# regression_suppression_survives_lineage_check.sh), then drive one more
# genuine false P0 claim to cross the default threshold of 3.
setup_test
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
    fail_not_implemented "BASHAUMA_SCHEDULER_CMD (A-0 threshold-crossing log)"
else
    assert_contains "$HARNESS_LAST_STDERR" "p_noisy" \
        "crossing the suppression threshold must log the pane_id (p_noisy) to stderr"
    assert_contains "$HARNESS_LAST_STDERR" "crossed P0 suppression threshold" \
        "crossing the suppression threshold must log the real A-0 event line to stderr (distinctive shape, not a bare keyword)"
fi
teardown_test

# --- Scenario B: suppressed-pane close-prune fires a log line ---------------
setup_test
seeded_state='{
  "epoch_fed_pane_ids": [],
  "pane_status": {},
  "first_runnable_at": {},
  "p0_demoted_pane_ids": ["p_gone"],
  "p0_suppressed_pane_ids": ["p_gone"],
  "demotion_count": {"p_gone": 3},
  "demotion_seq": {"p_gone": 5},
  "winner_fired_epoch": false,
  "last_winner_pane_id": null,
  "last_winner_was_p0": false
}'
printf '%s' "$seeded_state" >"$HERDR_PLUGIN_STATE_DIR/state.json"

# p_gone is NOT in this agent_list -- it has closed. p_other is the only
# live candidate, forcing a schedule() run that must prune p_gone's
# suppression bookkeeping.
stub_set_agent_list '[
  {"pane_id":"p_leave","agent_status":"working","state_change_seq":1,"tab_id":"t1","workspace_id":"ws1","cwd":"/repo","focused":true},
  {"pane_id":"p_other","agent_status":"idle","state_change_seq":8,"tab_id":"t9","workspace_id":"ws9","cwd":"/elsewhere","focused":false}
]'

invoke_status_changed "p_leave" "working"
rc=$?
if [ "$rc" -eq 127 ]; then
    fail_not_implemented "BASHAUMA_SCHEDULER_CMD (A-0 close-prune log)"
else
    assert_contains "$HARNESS_LAST_STDERR" "p_gone" \
        "close-pruning a suppressed pane must log the pane_id (p_gone) to stderr"
    assert_contains "$HARNESS_LAST_STDERR" "pruned on close" \
        "close-pruning a suppressed pane must log the real A-0 close-prune event line to stderr (distinctive shape, not a bare keyword)"
    suppressed_after=$(jq -r '(.p0_suppressed_pane_ids // []) | index("p_gone") != null' "$HERDR_PLUGIN_STATE_DIR/state.json")
    assert_eq "false" "$suppressed_after" \
        "p_gone's suppression record must actually be pruned (A-0 is diagnostic-only, no behavior regression)"
fi
teardown_test

# --- Scenario C: no spurious firing during ordinary operation ---------------
# A run-of-the-mill dispatch yield, a run-of-the-mill idle promotion, and a
# blocked pane that confirms P0 cleanly on its first try (no demotion at
# all) must produce zero suppression-flavored log output. A log that fires
# on every schedule() call regardless of whether a real crossing/prune
# happened would be evidence nobody could trust.
setup_test
stub_set_agent_list '[
  {"pane_id":"p_leave","agent_status":"working","state_change_seq":1,"tab_id":"t1","workspace_id":"ws1","cwd":"/repo","focused":true},
  {"pane_id":"p_idle","agent_status":"idle","state_change_seq":2,"tab_id":"t9","workspace_id":"ws9","cwd":"/x","focused":false},
  {"pane_id":"p_blocked_clean","agent_status":"blocked","state_change_seq":3,"tab_id":"t9","workspace_id":"ws9","cwd":"/x","focused":false}
]'
stub_set_pane_read "p_blocked_clean" <<EOF
$CONFIRM_HINT_LINE
EOF

invoke_status_changed "p_leave" "working"
rc=$?
if [ "$rc" -eq 127 ]; then
    fail_not_implemented "BASHAUMA_SCHEDULER_CMD (A-0 no spurious firing)"
else
    assert_not_contains "$HARNESS_LAST_STDERR" "crossed P0 suppression threshold" \
        "ordinary operation (no threshold crossing) must not emit the A-0 threshold-crossing log line"
    assert_not_contains "$HARNESS_LAST_STDERR" "pruned on close" \
        "ordinary operation (no close-prune) must not emit the A-0 close-prune log line"
fi
teardown_test

# --- Scenario D: explain must NOT pollute the A-0 log with a spurious ------
# --- (never-persisted) threshold-crossing event -----------------------------
# explain_decision() (lib/scheduler.sh) is documented as read-only: it
# never calls state_save, so a hypothetical false-claim demotion it
# computes to classify a candidate is discarded, not persisted. But
# _demote_pane_to_p1() -- the ONE function both schedule() and
# explain_decision() (via _classify_candidate) call to compute that
# hypothetical demotion -- writes its A-0 threshold-crossing log line to
# stderr UNCONDITIONALLY, regardless of whether the caller ever persists
# the result. This means a bare `explain` invocation (safe, side-effect
# free, and likely to be run MORE often than a real dispatch/`next` yield
# precisely because it's read-only) can emit a "crossed P0 suppression
# threshold" log line for a pane that was never actually suppressed --
# demotion_count in state.json is untouched. Since A-0's entire stated
# purpose is to be trustworthy evidence for a future decision about
# whether to build full demotion decay, a log line indistinguishable from
# a real crossing but fireable on repeat by a no-op read is exactly the
# "crying wolf" failure mode the task called out as disqualifying.
#
# The assertion below targets $HARNESS_LAST_STDERR specifically, and
# matches the real log line's distinctive text ("crossed P0 suppression
# threshold"), NOT a bare "suppress" keyword against the fused
# stdout+stderr stream. explain's stdout report is *expected* to name
# suppression by name -- the `p0_suppress_after_demotions` config key and
# a per-candidate `suppressed=` field are correct, useful diagnostic
# output; explaining suppression state is precisely explain's job. The
# defect this scenario pins is narrower: the real, persisted-event A-0
# log line must not appear on stderr as a side effect of a call that
# never persists anything (2026-08-20 correction, Hockney review
# follow-up -- see the file header comment for the full story of why a
# bare keyword check drove a bad fix the first time around).
setup_test
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

stub_set_agent_list '[
  {"pane_id":"p_leave","agent_status":"working","state_change_seq":1,"tab_id":"t1","workspace_id":"ws1","cwd":"/repo","focused":true},
  {"pane_id":"p_noisy","agent_status":"blocked","state_change_seq":20,"tab_id":"t9","workspace_id":"ws9","cwd":"/elsewhere","focused":false}
]'
stub_set_pane_read "p_noisy" <<EOF
$PLAIN_SCROLLBACK_LINE
EOF

invoke_explain "p_leave"
rc=$?
if [ "$rc" -eq 127 ]; then
    fail_not_implemented "BASHAUMA_EXPLAIN_CMD (explain must not spuriously log a threshold crossing)"
else
    assert_not_contains "$HARNESS_LAST_STDERR" "crossed P0 suppression threshold" \
        "a read-only explain call must NEVER emit the real A-0 threshold-crossing log line on stderr -- it never persists the demotion it hypothetically computed, so a log claiming one happened is false evidence"
    demotion_count_after=$(jq -r '.demotion_count.p_noisy // 0' "$HERDR_PLUGIN_STATE_DIR/state.json")
    assert_eq "2" "$demotion_count_after" \
        "explain must genuinely be read-only: demotion_count must be untouched in state.json after an explain call"
fi
teardown_test

harness_report_and_exit
