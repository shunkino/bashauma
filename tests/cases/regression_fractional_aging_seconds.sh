#!/bin/bash
# REGRESSION — fractional aging_seconds crashes schedule() entirely.
#
# prd.md's config table documents `aging_seconds` (default 300) with no
# stated integer-only constraint -- a user retuning it (e.g. `"aging_seconds":
# 30.5` to wait "half a minute past thirty seconds", or via
# BASHAUMA_AGING_SECONDS for one-off tuning, exactly as README.md's own
# "Configuration" section advertises) gets a value bash's `$(( ))` cannot
# parse.
#
# lib/scheduler.sh computes:
#   aging_threshold_ms=$((CONFIG_AGING_SECONDS * 1000))
# using bash's *integer-only* arithmetic evaluation. A fractional
# CONFIG_AGING_SECONDS makes this line fail at runtime with
# "syntax error: invalid arithmetic operator" and, under `set -euo
# pipefail`, aborts the whole schedule() call.
#
# Net effect verified by hand (not simulated): a genuine dispatch-yield
# event with BASHAUMA_AGING_SECONDS=0.5 crashes on_status_changed.sh with
# exit 1 -- the state lock IS released correctly (EXIT trap), so this is
# not a lock-wedge, but the dispatch yield is silently dropped: no
# candidate is picked, no `agent focus` happens, and the event is lost
# with only a stderr syntax error and no user-facing signal at all. Same
# crash reachable via `blocked_confirm_lines`, or any other CONFIG_* value
# reaching `$(( ))` un-sanitized, if ever made fractional -- this test
# pins the aging_seconds case as the concrete, PRD-legal instance.
#
# EXPECTED TO FAIL until lib/scheduler.sh/lib/config.sh either (a) coerce
# */validate CONFIG_AGING_SECONDS (and any other value reaching bash
# arithmetic) to an integer at load time, or (b) use `awk`/`bc`-based
# comparison instead of bash integer arithmetic for the aging deadline.
set -u
. "$(dirname "$0")/../lib/harness.sh"

setup_test
stub_set_agent_list '[
  {"pane_id":"p1","agent_status":"working","state_change_seq":1,"tab_id":"t1","workspace_id":"ws1","cwd":"/repo","focused":true},
  {"pane_id":"p2","agent_status":"idle","state_change_seq":2,"tab_id":"t1","workspace_id":"ws1","cwd":"/repo","focused":false}
]'
export BASHAUMA_AGING_SECONDS=0.5

invoke_status_changed "p1" "working"
rc=$?
if [ "$rc" -eq 127 ]; then
    fail_not_implemented "BASHAUMA_SCHEDULER_CMD (fractional aging_seconds regression)"
else
    assert_exit_code 0 "$rc" "on_status_changed.sh must not crash on a fractional (but PRD-legal) aging_seconds value"
    assert_focus_call_count 1 "a dispatch yield with a fractional aging_seconds must still schedule and move focus, not silently drop the yield"
fi
teardown_test

harness_report_and_exit
