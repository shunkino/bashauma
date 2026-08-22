#!/bin/bash
# Hockney review coverage for GitHub issue #4 / keyword-based transition hold.
# Extends Fenster's floor-level tests with the hard invariants from the
# proactive plan: exact hold-event stderr text, next as escape hatch, default
# inert command transcript, richer bottom-anchoring/config traps, hold lineage,
# determinism, and read-cost bounds.
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

_many_idle_json() {
    cat <<'JSON'
[
  {"pane_id":"p_leave","agent_status":"working","state_change_seq":10,"tab_id":"t1","workspace_id":"ws1","cwd":"/repo","focused":true},
  {"pane_id":"p_a","agent_status":"idle","state_change_seq":20,"tab_id":"t9","workspace_id":"ws9","cwd":"/elsewhere","focused":false},
  {"pane_id":"p_b","agent_status":"idle","state_change_seq":21,"tab_id":"t9","workspace_id":"ws9","cwd":"/elsewhere","focused":false},
  {"pane_id":"p_c","agent_status":"idle","state_change_seq":22,"tab_id":"t9","workspace_id":"ws9","cwd":"/elsewhere","focused":false},
  {"pane_id":"p_d","agent_status":"idle","state_change_seq":23,"tab_id":"t9","workspace_id":"ws9","cwd":"/elsewhere","focused":false},
  {"pane_id":"p_e","agent_status":"idle","state_change_seq":24,"tab_id":"t9","workspace_id":"ws9","cwd":"/elsewhere","focused":false}
]
JSON
}

write_config() { # JSON object body
    export HERDR_PLUGIN_CONFIG_DIR="$HERDR_PLUGIN_STATE_DIR"
    printf '%s\n' "$1" >"$HERDR_PLUGIN_CONFIG_DIR/config.json"
}

pane_read_count() {
    herdr_invocation_log | grep -c '^pane read ' || true
}

pane_read_lines() {
    herdr_invocation_log | grep '^pane read ' || true
}

normalize_state_for_hold_determinism() {
    jq -c 'del(.last_hold_at, .first_runnable_at)' "$1"
}

# --- exact mandatory hold log line -----------------------------------------
setup_test
write_config '{"hold_keywords":["run the command (y/n)?"]}'
stub_set_agent_list "$(_two_panes_json)"
stub_set_pane_read "p_leave" <<'SCROLL'
Please run the command (y/n)?
SCROLL

invoke_status_changed "p_leave" "working"
rc=$?
if [ "$rc" -eq 127 ]; then
    fail_not_implemented "BASHAUMA_SCHEDULER_CMD (exact hold log line)"
else
    expected_log='bashauma: held pane p_leave on dispatch yield (matched keyword: "run the command (y/n)?")'
    assert_eq "$HARNESS_LAST_STDERR" "$expected_log" \
        "hold events must log the exact A-0 stderr line, because the hold is otherwise silent"
    assert_focus_not_called "a logged hold must suppress focus"
fi
teardown_test

# --- explicit next must bypass hold even with matching departure text --------
setup_test
write_config '{"hold_keywords":["run the following command"]}'
stub_set_agent_list "$(_two_panes_json)"
stub_set_pane_read "p_leave" <<'SCROLL'
run the following command
SCROLL

invoke_status_changed "p_leave" "working"
rc=$?
if [ "$rc" -eq 127 ]; then
    fail_not_implemented "BASHAUMA_SCHEDULER_CMD (dispatch hold before next escape)"
else
    assert_focus_not_called "dispatch with a matching hold keyword must not focus"
    assert_contains "$HARNESS_LAST_STDERR" 'bashauma: held pane p_leave on dispatch yield (matched keyword: "run the following command")' \
        "dispatch hold must log before the next escape"
fi
: >"$HERDR_STUB_LOG"
: >"$HERDR_STUB_DIR/focus_calls.log"
invoke_next "p_leave"
rc=$?
if [ "$rc" -eq 127 ]; then
    fail_not_implemented "BASHAUMA_NEXT_CMD (next must bypass hold)"
else
    assert_focus_called_with "p_next" "explicit next must schedule normally even when departure text still matches hold"
    assert_eq "$(pane_read_count)" "0" "explicit next must not spend the departure-pane hold read"
    assert_not_contains "$HARNESS_LAST_STDERR" "bashauma: held pane" "explicit next must not emit a hold log"
fi
teardown_test

# --- default inert transcript: no hold config means no pane read -------------
setup_test
stub_set_agent_list "$(_two_panes_json)"
stub_set_pane_read "p_leave" <<'SCROLL'
run the following command
SCROLL

invoke_status_changed "p_leave" "working"
rc=$?
if [ "$rc" -eq 127 ]; then
    fail_not_implemented "BASHAUMA_SCHEDULER_CMD (default inert transcript)"
else
    expected_log='agent get p_leave
agent list
agent focus p_next'
    assert_eq "$(herdr_invocation_log)" "$expected_log" \
        "default empty hold_keywords/hold_pattern must preserve the exact command transcript (no departure pane read)"
    assert_eq "$HARNESS_LAST_STDERR" "" "default hold config must be silent on stderr"
    assert_focus_called_with "p_next" "default hold config must preserve the normal winner"
fi
teardown_test

# --- explicit empty hold config is equally inert ----------------------------
setup_test
write_config '{"hold_keywords":[],"hold_pattern":""}'
stub_set_agent_list "$(_two_panes_json)"
stub_set_pane_read "p_leave" <<'SCROLL'
run the following command
SCROLL
invoke_status_changed "p_leave" "working"
rc=$?
if [ "$rc" -ne 127 ]; then
    expected_log='agent get p_leave
agent list
agent focus p_next'
    assert_eq "$(herdr_invocation_log)" "$expected_log" \
        "explicit empty hold config must also preserve the exact command transcript"
    assert_eq "$HARNESS_LAST_STDERR" "" "explicit empty hold config must be silent"
fi
teardown_test

# --- default bottom window is 15 non-empty lines ----------------------------
setup_test
write_config '{"hold_keywords":["open your browser"]}'
stub_set_agent_list "$(_two_panes_json)"
stub_set_pane_read "p_leave" <<'SCROLL'
open your browser
fresh 01
fresh 02
fresh 03
fresh 04
fresh 05
fresh 06
fresh 07
fresh 08
fresh 09
fresh 10
fresh 11
fresh 12
fresh 13
fresh 14
fresh 15
fresh 16
SCROLL
invoke_status_changed "p_leave" "working"
rc=$?
if [ "$rc" -ne 127 ]; then
    assert_focus_called_with "p_next" "keyword above the bottom 15 non-empty lines must not hold"
    assert_not_contains "$HARNESS_LAST_STDERR" "bashauma: held pane" "stale hold keyword above bottom window must not log"
fi
teardown_test

setup_test
write_config '{"hold_keywords":["open your browser"]}'
stub_set_agent_list "$(_two_panes_json)"
stub_set_pane_read "p_leave" <<'SCROLL'
fresh 01
fresh 02
open your browser
fresh 03
fresh 04
fresh 05
fresh 06
fresh 07
fresh 08
fresh 09
fresh 10
fresh 11
fresh 12
fresh 13
fresh 14
fresh 15
SCROLL
invoke_status_changed "p_leave" "working"
rc=$?
if [ "$rc" -ne 127 ]; then
    assert_focus_not_called "keyword within the default bottom 15 non-empty lines must hold"
    assert_contains "$HARNESS_LAST_STDERR" 'matched keyword: "open your browser"' "bottom-window keyword must be reported"
fi
teardown_test

# --- hold_check_lines knob --------------------------------------------------
setup_test
write_config '{"hold_keywords":["navigate to"],"hold_check_lines":2}'
stub_set_agent_list "$(_two_panes_json)"
stub_set_pane_read "p_leave" <<'SCROLL'
navigate to settings
fresh 1
fresh 2
SCROLL
invoke_status_changed "p_leave" "working"
rc=$?
if [ "$rc" -ne 127 ]; then
    assert_focus_called_with "p_next" "hold_check_lines=2 excludes a keyword three non-empty lines from the bottom"
fi
teardown_test

# --- config matching traps: regex metacharacters are literal ----------------
setup_test
write_config '{"hold_keywords":["a.b"]}'
stub_set_agent_list "$(_two_panes_json)"
stub_set_pane_read "p_leave" <<'SCROLL'
axb
SCROLL
invoke_status_changed "p_leave" "working"
rc=$?
if [ "$rc" -ne 127 ]; then
    assert_focus_called_with "p_next" "fixed-string keyword a.b must not regex-match axb"
fi
teardown_test

setup_test
write_config '{"hold_keywords":["a.b"]}'
stub_set_agent_list "$(_two_panes_json)"
stub_set_pane_read "p_leave" <<'SCROLL'
a.b
SCROLL
invoke_status_changed "p_leave" "working"
rc=$?
if [ "$rc" -ne 127 ]; then
    assert_focus_not_called "fixed-string keyword a.b must match literal a.b"
    assert_contains "$HARNESS_LAST_STDERR" 'matched keyword: "a.b"' "literal metacharacter keyword must be logged exactly"
fi
teardown_test

setup_test
write_config '{"hold_keywords":["-danger"]}'
stub_set_agent_list "$(_two_panes_json)"
stub_set_pane_read "p_leave" <<'SCROLL'
-dangER
SCROLL
invoke_status_changed "p_leave" "working"
rc=$?
if [ "$rc" -ne 127 ]; then
    assert_focus_not_called "keyword beginning with '-' must not be parsed as a grep option"
    assert_contains "$HARNESS_LAST_STDERR" 'matched keyword: "-danger"' "leading-dash keyword must be logged exactly"
fi
teardown_test

setup_test
write_config '{"hold_keywords":["OPEN YOUR BROWSER"]}'
stub_set_agent_list "$(_two_panes_json)"
stub_set_pane_read "p_leave" <<'SCROLL'
please open your browser now
SCROLL
invoke_status_changed "p_leave" "working"
rc=$?
if [ "$rc" -ne 127 ]; then
    assert_focus_not_called "hold_keywords must match case-insensitively"
fi
teardown_test

setup_test
write_config '{"hold_pattern":"run (this|that)"}'
stub_set_agent_list "$(_two_panes_json)"
stub_set_pane_read "p_leave" <<'SCROLL'
please run that
SCROLL
invoke_status_changed "p_leave" "working"
rc=$?
if [ "$rc" -ne 127 ]; then
    assert_focus_not_called "hold_pattern must provide an intentional ERE override"
    assert_contains "$HARNESS_LAST_STDERR" 'matched pattern: "run (this|that)"' "pattern matches must be identified as pattern matches"
fi
teardown_test

# --- hold de-exemption must not survive pane-ID recycle ---------------------
setup_test
write_config '{"hold_keywords":["navigate to"]}'
cat >"$HERDR_PLUGIN_STATE_DIR/state.json" <<'JSON'
{
  "epoch_fed_pane_ids": [],
  "pane_status": {},
  "first_runnable_at": {},
  "p0_demoted_pane_ids": [],
  "p0_suppressed_pane_ids": [],
  "demotion_count": {},
  "demotion_seq": {},
  "hold_count": {"p_recycled": 1},
  "last_hold_at": {"p_recycled": 1787345660000},
  "hold_seq": {"p_recycled": 50},
  "false_hold_count": {"p_recycled": 1},
  "last_hold_pane_id": null,
  "winner_fired_epoch": false,
  "last_winner_pane_id": null,
  "last_winner_was_p0": false
}
JSON
stub_set_agent_list '[
  {"pane_id":"p_recycled","agent_status":"working","state_change_seq":3,"tab_id":"t1","workspace_id":"ws1","cwd":"/repo","focused":true},
  {"pane_id":"p_next","agent_status":"idle","state_change_seq":20,"tab_id":"t2","workspace_id":"ws2","cwd":"/repo","focused":false}
]'
stub_set_pane_read "p_recycled" <<'SCROLL'
navigate to settings
SCROLL
invoke_status_changed "p_recycled" "working"
rc=$?
if [ "$rc" -ne 127 ]; then
    assert_focus_not_called "a recycled pane ID with lower seq must not inherit stale hold exemption"
    assert_contains "$HARNESS_LAST_STDERR" 'bashauma: held pane p_recycled on dispatch yield (matched keyword: "navigate to")' \
        "recycled pane must be treated as fresh and held"
    new_seq=$(jq -r '.hold_seq.p_recycled // empty' "$HERDR_PLUGIN_STATE_DIR/state.json")
    assert_eq "$new_seq" "3" "recycled pane hold_seq must be restamped to the observed new lineage"
fi
teardown_test

# --- valid exemption must survive normal lineage progression ----------------
setup_test
write_config '{"hold_keywords":["navigate to"]}'
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
  "false_hold_count": {"p_leave": 1},
  "last_hold_pane_id": null,
  "winner_fired_epoch": false,
  "last_winner_pane_id": null,
  "last_winner_was_p0": false
}
JSON
stub_set_agent_list "$(_two_panes_json)"
stub_set_pane_read "p_leave" <<'SCROLL'
navigate to settings
SCROLL
invoke_status_changed "p_leave" "working"
rc=$?
if [ "$rc" -ne 127 ]; then
    assert_focus_called_with "p_next" "same-lineage false-hold exemption must survive normal state_change_seq progression"
    assert_not_contains "$HARNESS_LAST_STDERR" "bashauma: held pane" "hold-exempt same-lineage pane must not log another hold"
    still_exempt=$(jq -r '.false_hold_count.p_leave // 0' "$HERDR_PLUGIN_STATE_DIR/state.json")
    assert_eq "$still_exempt" "1" "same-lineage exemption state must not be forgotten"
fi
teardown_test

# --- cost: one departure read per dispatch, no per-candidate reads ----------
setup_test
write_config '{"hold_keywords":["please stay here"]}'
stub_set_agent_list "$(_many_idle_json)"
stub_set_pane_read "p_leave" <<'SCROLL'
ordinary output
SCROLL
invoke_status_changed "p_leave" "working"
rc=$?
if [ "$rc" -ne 127 ]; then
    assert_eq "$(pane_read_count)" "1" "configured dispatch hold check must spend exactly one pane read"
    assert_eq "$(pane_read_lines)" "pane read p_leave --source visible" "the sole hold read must target the departure pane, not candidates"
    assert_focus_called_with "p_a" "non-matching hold still schedules normally after one departure read"
fi
teardown_test

# --- determinism: same state gives same winner/no-winner --------------------
setup_test
write_config '{"hold_keywords":["please stay here"]}'
stub_set_agent_list '[
  {"pane_id":"p_leave","agent_status":"working","state_change_seq":10,"tab_id":"t1","workspace_id":"ws1","cwd":"/repo","focused":true},
  {"pane_id":"p_b","agent_status":"idle","state_change_seq":20,"tab_id":"t9","workspace_id":"ws9","cwd":"/elsewhere","focused":false},
  {"pane_id":"p_a","agent_status":"idle","state_change_seq":20,"tab_id":"t9","workspace_id":"ws9","cwd":"/elsewhere","focused":false}
]'
stub_set_pane_read "p_leave" <<'SCROLL'
ordinary output
SCROLL
invoke_status_changed "p_leave" "working"
winner_one=$(focus_calls | tail -n 1)
state_one=$(normalize_state_for_hold_determinism "$HERDR_PLUGIN_STATE_DIR/state.json")
teardown_test

setup_test
write_config '{"hold_keywords":["please stay here"]}'
stub_set_agent_list '[
  {"pane_id":"p_leave","agent_status":"working","state_change_seq":10,"tab_id":"t1","workspace_id":"ws1","cwd":"/repo","focused":true},
  {"pane_id":"p_b","agent_status":"idle","state_change_seq":20,"tab_id":"t9","workspace_id":"ws9","cwd":"/elsewhere","focused":false},
  {"pane_id":"p_a","agent_status":"idle","state_change_seq":20,"tab_id":"t9","workspace_id":"ws9","cwd":"/elsewhere","focused":false}
]'
stub_set_pane_read "p_leave" <<'SCROLL'
ordinary output
SCROLL
invoke_status_changed "p_leave" "working"
winner_two=$(focus_calls | tail -n 1)
state_two=$(normalize_state_for_hold_determinism "$HERDR_PLUGIN_STATE_DIR/state.json")
assert_eq "$winner_one" "$winner_two" "identical non-hold queue state must pick the same winner"
assert_eq "$winner_one" "p_a" "total deterministic tiebreak must use pane_id when seq also ties"
assert_eq "$state_one" "$state_two" "identical non-hold queue state must produce identical canonical state"
teardown_test

setup_test
write_config '{"hold_keywords":["please stay here"]}'
stub_set_agent_list "$(_two_panes_json)"
stub_set_pane_read "p_leave" <<'SCROLL'
please stay here
SCROLL
invoke_status_changed "p_leave" "working"
held_one=$(focus_call_count)
state_one=$(normalize_state_for_hold_determinism "$HERDR_PLUGIN_STATE_DIR/state.json")
teardown_test

setup_test
write_config '{"hold_keywords":["please stay here"]}'
stub_set_agent_list "$(_two_panes_json)"
stub_set_pane_read "p_leave" <<'SCROLL'
please stay here
SCROLL
invoke_status_changed "p_leave" "working"
held_two=$(focus_call_count)
state_two=$(normalize_state_for_hold_determinism "$HERDR_PLUGIN_STATE_DIR/state.json")
assert_eq "$held_one" "$held_two" "identical hold-matching queue state must produce the same no-focus outcome"
assert_eq "$held_two" "0" "hold determinism scenario should hold in both runs"
assert_eq "$state_one" "$state_two" "identical hold-matching queue state must produce identical canonical state after timestamp normalization"
teardown_test

harness_report_and_exit
