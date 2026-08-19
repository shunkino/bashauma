#!/bin/bash
# REGRESSION — concurrency: external herdr calls must not happen while the
# state lock is held.
#
# prd.md §6.7: "All writes are serialized with an atomic lock, since the
# event hook can run concurrently for several panes." The lock exists to
# protect the read-modify-write of state.json, which is a fast local file
# operation. It is NOT meant to serialize slow, external I/O (`agent list`,
# and one `pane read` per blocked candidate for §6.2 bottom-anchored
# confirmation) across concurrent event-hook invocations.
#
# lib/scheduler.sh's schedule() currently acquires the state lock BEFORE
# calling agent_list_json() and BEFORE the candidate-building loop that
# calls confirm_p0() (-> `herdr pane read`) once per blocked candidate, and
# only releases the lock afterward, right before issuing `agent focus`.
# This means:
#
#   1. Every concurrent dispatch/next yield across ALL panes is serialized
#      behind however long `agent list` + N `pane read` calls take for
#      whichever yield got the lock first -- for an epoch with several
#      blocked candidates, that's N sequential round-trips to herdr held
#      under one global lock, not just a JSON write.
#   2. Worse: lib/state.sh's stale-lock reclaim heuristic
#      (STATE_LOCK_STALE_SECONDS, default 30s) assumes a lock held longer
#      than the timeout means the holder died. If `pane read`/`agent list`
#      genuinely takes that long (a slow/hung herdr, or just many blocked
#      candidates), a *second*, concurrent yield will force-break the lock
#      out from under the still-alive first holder, and BOTH processes end
#      up believing they hold the lock -- a real double-writer / lost-update
#      hazard on state.json, and potentially two conflicting `agent focus`
#      decisions for the same epoch.
#
# This test proves defect (1)'s root cause deterministically and without
# any timing races: it demonstrates that `agent list` and `pane read` are,
# in fact, invoked while $HERDR_PLUGIN_STATE_DIR/state.lock exists. See
# tests/fixtures/bin/herdr's lock_held_during.log instrumentation.
#
# EXPECTED TO FAIL until lib/scheduler.sh moves external herdr calls (agent
# list, and confirm_p0's pane read) outside the state_acquire_lock /
# state_release_lock section -- e.g. snapshot agent_list first, release
# the lock (or use a separate, short-lived lock) while doing candidate
# confirmation reads, then re-acquire only for the final state mutation +
# decision.
set -u
. "$(dirname "$0")/../lib/harness.sh"

CONFIRM_HINT_LINE='│ ↑/↓ to select · enter to confirm · esc to cancel │'

setup_test
stub_set_agent_list '[
  {"pane_id":"p_leave","agent_status":"working","state_change_seq":1,"tab_id":"t1","workspace_id":"ws1","cwd":"/repo","focused":true},
  {"pane_id":"p_blocked","agent_status":"blocked","state_change_seq":2,"tab_id":"t9","workspace_id":"ws9","cwd":"/elsewhere","focused":false}
]'
stub_set_pane_read "p_blocked" <<EOF
$CONFIRM_HINT_LINE
EOF

invoke_status_changed "p_leave" "working"
rc=$?
if [ "$rc" -eq 127 ]; then
    fail_not_implemented "BASHAUMA_SCHEDULER_CMD (lock-scope regression)"
else
    assert_no_calls_while_state_lock_held \
        "agent list / pane read must happen outside the state lock (see header comment for why this matters for the stale-lock reclaim heuristic)"
fi
teardown_test

harness_report_and_exit
