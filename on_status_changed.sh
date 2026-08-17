#!/bin/bash
# bashauma: on pane.agent_status_changed
#
# Fires every time any agent pane's status changes. We treat a transition
# into "working" as "the user just dispatched a task to this pane" (see
# prd.md 6.4). On that signal we:
#   1. Debounce: some agents (e.g. GitHub Copilot CLI opening/closing its
#      "tasks" sub-view) redraw the terminal in a way that briefly flips the
#      detected status to "working" and back, with no real prompt dispatch.
#      We re-check the pane's status after a short delay and bail out if it
#      already reverted, so only a sustained "working" state counts.
#   2. Mark the pane as "done for this round" in state under
#      HERDR_PLUGIN_STATE_DIR.
#   3. Recompute currently-open agent panes (agent.list) and drop any
#      done/closed panes that no longer exist, so closed tabs never block
#      round completion.
#   4. If every open pane is now done, celebrate with the winner popup and
#      reset the round. Otherwise, auto-focus the next undone pane to nudge
#      the user toward it.
set -euo pipefail

HERDR="${HERDR_BIN_PATH:-herdr}"
STATE_DIR="${HERDR_PLUGIN_STATE_DIR:-${TMPDIR:-/tmp}}"
STATE_FILE="$STATE_DIR/round.json"
PLUGIN_ID="bashauma"
DEBOUNCE_SECONDS="${BASHAUMA_DEBOUNCE_SECONDS:-1.5}"

pane_id=$(printf '%s' "${HERDR_PLUGIN_EVENT_JSON:-}" | jq -r '.pane_id // .data.pane_id // empty' 2>/dev/null)
agent_status=$(printf '%s' "${HERDR_PLUGIN_EVENT_JSON:-}" | jq -r '.agent_status // .data.agent_status // empty' 2>/dev/null)

[ -n "$pane_id" ] || exit 0
[ "$agent_status" = "working" ] || exit 0

# Confirm the "working" status sticks around; a momentary blip (e.g. a
# sub-view opening/closing in the agent's TUI) reverts before the debounce
# elapses and is not a real task dispatch.
sleep "$DEBOUNCE_SECONDS"
current_status=$("$HERDR" agent get "$pane_id" 2>/dev/null | jq -r '.result.agent.agent_status // empty')
[ "$current_status" = "working" ] || exit 0

[ -f "$STATE_FILE" ] || echo '{"round_done_pane_ids":[]}' > "$STATE_FILE"

# Currently open agent panes, in the order agent.list reports them
# (creation/tab order) — this is also the deterministic redirect order.
open_ids_json=$("$HERDR" agent list 2>/dev/null | jq -c '[.result.agents[].pane_id]')

# Mark this pane done, then drop any done pane_id that is no longer open
# (agent exited / pane closed) so it can't block round completion forever.
done_ids_json=$(jq -c --arg pane "$pane_id" --argjson open "$open_ids_json" \
    '(.round_done_pane_ids + [$pane]) | unique | map(select(. as $p | $open | index($p) != null))' \
    "$STATE_FILE")

open_count=$(printf '%s' "$open_ids_json" | jq 'length')
done_count=$(printf '%s' "$done_ids_json" | jq 'length')

if [ "$open_count" -gt 0 ] && [ "$open_count" -eq "$done_count" ]; then
    # Round complete: every open pane has received a task this round.
    echo '{"round_done_pane_ids":[]}' > "$STATE_FILE"
    "$HERDR" plugin pane open --plugin "$PLUGIN_ID" --entrypoint winner --focus >/dev/null 2>&1 || true
    exit 0
fi

echo "{\"round_done_pane_ids\":$done_ids_json}" > "$STATE_FILE"

# Redirect focus to the first undone open pane (deterministic tab order).
next_pane=$(jq -r --argjson done "$done_ids_json" \
    '(. - $done) | .[0] // empty' \
    <<< "$open_ids_json")

if [ -n "$next_pane" ]; then
    "$HERDR" agent focus "$next_pane" >/dev/null 2>&1 || true
fi
