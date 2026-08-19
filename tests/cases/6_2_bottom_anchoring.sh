#!/bin/bash
# PRD §6.2 — Bottom-anchoring of the blocked confirmation check.
#
# "Bottom-anchoring is the entire point: herdr's Copilot rule scans a long
# `whole_recent` window, so any pane that merely *mentions* those phrases
# anywhere in recent scrollback is flagged." A pane whose scrollback
# mentions the prompt phrases only in OLD output (not within the bottom
# `blocked_confirm_lines` non-empty lines) must NOT be treated as P0 — this
# is the false positive measured in prd.md §14.
set -u
. "$(dirname "$0")/../lib/harness.sh"

setup_test
stub_set_agent_list '[
  {"pane_id":"w1:leaving","agent_status":"working","state_change_seq":1,"tab_id":"t1","workspace_id":"ws1","cwd":"/repo","focused":true},
  {"pane_id":"w1:idle-near","agent_status":"idle","state_change_seq":2,"tab_id":"t1","workspace_id":"ws1","cwd":"/repo","focused":false},
  {"pane_id":"w1:blocked-stale-hint","agent_status":"blocked","state_change_seq":3,"tab_id":"t9","workspace_id":"ws9","cwd":"/elsewhere","focused":false}
]'
# The prompt-hint phrases appear ONLY near the top of scrollback (old
# output, e.g. a command that printed help text mentioning esc/enter), with
# many non-empty lines of unrelated, currently-active output beneath them.
# Default blocked_confirm_lines is 5 — put 10 unrelated lines after the hint.
stub_set_pane_read "w1:blocked-stale-hint" <<'EOF'
$ cat old-help-text.txt
usage: some-tool [options]
  esc to cancel, enter to confirm  (this is stale --help output, not a live prompt)
---
line 1 of fresh unrelated output
line 2 of fresh unrelated output
line 3 of fresh unrelated output
line 4 of fresh unrelated output
line 5 of fresh unrelated output
line 6 of fresh unrelated output
line 7 of fresh unrelated output
line 8 of fresh unrelated output
line 9 of fresh unrelated output
line 10 of fresh unrelated output (bottom of scrollback, no prompt hint here)
EOF

invoke_status_changed "w1:leaving" "working"
rc=$?
if [ "$rc" -eq 127 ]; then
    fail_not_implemented "BASHAUMA_SCHEDULER_CMD (bottom-anchored confirmation / §6.2)"
else
    assert_not_contains "$(focus_calls)" "w1:blocked-stale-hint" \
        "prompt hint only in old (non-bottom) scrollback must NOT confirm P0"
    assert_focus_called_with "w1:idle-near" \
        "falls through to the P1 candidate instead of the falsely-flagged blocked pane"
fi
teardown_test

harness_report_and_exit
