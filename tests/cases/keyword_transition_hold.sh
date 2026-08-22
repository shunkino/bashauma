#!/bin/bash
# GitHub issue #4 / design item C: keyword-based transition hold.
#
# The hold is dispatch-only, inert by default, bottom-anchored to the
# departure pane's visible output, fixed-string for hold_keywords, and
# self-corrects when an immediate explicit `next` proves the hold false.
set -u
. "$(dirname "$0")/../lib/harness.sh"

_two_panes_json() {
    cat <<'JSON'
[
  {"pane_id":"p_leave","agent_status":"working","state_change_seq":10,"tab_id":"t1","workspace_id":"ws1","cwd":"/repo","focused":true},
  {"pane_id":"p_next","agent_status":"idle","state_change_seq":20,"tab_id":"t2","workspace_id":"ws2","cwd":"/repo","focused":false}
]
JSON
}

# --- inert by default: no configured hold means no extra departure pane read
setup_test
stub_set_agent_list "$(_two_panes_json)"
stub_set_pane_read "p_leave" <<'EOF'
run the following command
EOF

invoke_status_changed "p_leave" "working"
rc=$?
if [ "$rc" -eq 127 ]; then
    fail_not_implemented "BASHAUMA_SCHEDULER_CMD (hold inert by default)"
else
    assert_focus_called_with "p_next" "default empty hold config must preserve the normal dispatch move"
    assert_not_contains "$(herdr_invocation_log)" "pane read p_leave" "unconfigured hold must not read the departure pane"
    assert_not_contains "$HARNESS_LAST_STDERR" "bashauma: held pane" "unconfigured hold must not log"
fi
teardown_test

# --- bottom anchoring: stale scrollback above the configured window is ignored
setup_test
export BASHAUMA_HOLD_KEYWORDS="run the following command"
export BASHAUMA_HOLD_CHECK_LINES=2
stub_set_agent_list "$(_two_panes_json)"
stub_set_pane_read "p_leave" <<'EOF'
run the following command
ordinary line one
ordinary line two
EOF

invoke_status_changed "p_leave" "working"
rc=$?
if [ "$rc" -eq 127 ]; then
    fail_not_implemented "BASHAUMA_SCHEDULER_CMD (hold bottom anchoring)"
else
    assert_focus_called_with "p_next" "hold matching must ignore stale text above the bottom hold_check_lines window"
    assert_not_contains "$HARNESS_LAST_STDERR" "bashauma: held pane" "stale text outside the bottom window must not hold"
fi
unset BASHAUMA_HOLD_KEYWORDS BASHAUMA_HOLD_CHECK_LINES
teardown_test

# --- fixed string: regex metacharacters in a keyword are literal
setup_test
export BASHAUMA_HOLD_KEYWORDS="run [this]"
stub_set_agent_list "$(_two_panes_json)"
stub_set_pane_read "p_leave" <<'EOF'
Please RUN [THIS] now.
EOF

invoke_status_changed "p_leave" "working"
rc=$?
if [ "$rc" -eq 127 ]; then
    fail_not_implemented "BASHAUMA_SCHEDULER_CMD (hold fixed-string keyword)"
else
    assert_focus_not_called "a matching dispatch hold must suppress agent focus"
    assert_contains "$HARNESS_LAST_STDERR" 'bashauma: held pane p_leave on dispatch yield (matched keyword: "run [this]")' \
        "hold log line must name the held pane and fixed-string keyword"
    fed=$(jq -r '(.epoch_fed_pane_ids // []) | index("p_leave") != null' "$HERDR_PLUGIN_STATE_DIR/state.json")
    assert_eq "$fed" "true" "a held dispatch must still mark the departure pane fed"
fi
unset BASHAUMA_HOLD_KEYWORDS
teardown_test

# --- explicit next bypasses hold and makes that pane hold-exempt afterward
setup_test
export BASHAUMA_HOLD_KEYWORDS="run the following command"
stub_set_agent_list "$(_two_panes_json)"
stub_set_pane_read "p_leave" <<'EOF'
run the following command
EOF
cat >"$HERDR_PLUGIN_STATE_DIR/state.json" <<'JSON'
{
  "epoch_fed_pane_ids": [],
  "pane_status": {},
  "first_runnable_at": {},
  "p0_demoted_pane_ids": [],
  "p0_suppressed_pane_ids": [],
  "demotion_count": {},
  "demotion_seq": {},
  "hold_count": {"p_leave": 1},
  "last_hold_at": {"p_leave": 1787345660000},
  "hold_seq": {"p_leave": 10},
  "false_hold_count": {},
  "last_hold_pane_id": "p_leave",
  "winner_fired_epoch": false,
  "last_winner_pane_id": null,
  "last_winner_was_p0": false
}
JSON

invoke_next "p_leave"
rc=$?
if [ "$rc" -eq 127 ]; then
    fail_not_implemented "BASHAUMA_NEXT_CMD (next bypasses hold)"
else
    assert_focus_called_with "p_next" "explicit next must bypass a matching hold"
    assert_not_contains "$(herdr_invocation_log)" "pane read p_leave" "explicit next must not perform the hold pane read"
    false_count=$(jq -r '.false_hold_count.p_leave // 0' "$HERDR_PLUGIN_STATE_DIR/state.json")
    assert_eq "$false_count" "1" "next immediately after a same-lineage hold increments false_hold_count"
fi

: >"$HERDR_STUB_DIR/focus_calls.log"
invoke_status_changed "p_leave" "working"
rc=$?
if [ "$rc" -ne 127 ]; then
    assert_focus_called_with "p_next" "default hold_suppress_after=1 must make the pane hold-exempt after one immediate next override"
    assert_not_contains "$HARNESS_LAST_STDERR" "bashauma: held pane" "a hold-exempt pane must not log another hold"
fi
unset BASHAUMA_HOLD_KEYWORDS
teardown_test

harness_report_and_exit
