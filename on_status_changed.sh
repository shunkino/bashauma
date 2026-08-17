#!/bin/bash
# bashauma: on pane.agent_status_changed
#
# Fires every time any agent pane's status changes. Two independent
# behaviors live here:
#
#   A. Dispatch tracking (agent_status becomes "working"): treated as "the
#      user just sent this pane a task" (see prd.md 6.4). Marks the pane
#      done for the round, drops closed/stale panes, and either redirects
#      focus to the next undone pane or — once every open pane is done —
#      shows the winner popup and resets the round.
#
#   B. Finish-focus (agent_status leaves "working" for idle/done/blocked):
#      treated as "this agent just finished and needs attention". Redirects
#      focus to it, UNLESS the user currently appears to be actively
#      engaged with whatever pane they're already focused on (typing, or
#      watching fresh output stream in), in which case we leave them alone.
#
# Both transitions are debounced/re-verified before acting, because some
# agents (e.g. GitHub Copilot CLI opening/closing its "tasks" sub-view)
# redraw the terminal in a way that briefly flips the detected status and
# back, with no real dispatch or finish behind it.
set -euo pipefail

HERDR="${HERDR_BIN_PATH:-herdr}"
STATE_DIR="${HERDR_PLUGIN_STATE_DIR:-${TMPDIR:-/tmp}}"
STATE_FILE="$STATE_DIR/round.json"
PANE_STATUS_FILE="$STATE_DIR/pane_status.json"
PLUGIN_ID="bashauma"
DEBOUNCE_SECONDS="${BASHAUMA_DEBOUNCE_SECONDS:-1.5}"
ACTIVITY_CHECK_SECONDS="${BASHAUMA_ACTIVITY_CHECK_SECONDS:-0.5}"

pane_id=$(printf '%s' "${HERDR_PLUGIN_EVENT_JSON:-}" | jq -r '.pane_id // .data.pane_id // empty' 2>/dev/null)
agent_status=$(printf '%s' "${HERDR_PLUGIN_EVENT_JSON:-}" | jq -r '.agent_status // .data.agent_status // empty' 2>/dev/null)

[ -n "$pane_id" ] || exit 0
[ -n "$agent_status" ] || exit 0

[ -f "$PANE_STATUS_FILE" ] || echo '{}' > "$PANE_STATUS_FILE"
prev_status=$(jq -r --arg p "$pane_id" '.[$p] // "unknown"' "$PANE_STATUS_FILE")

remember_status() { # $1 pane_id, $2 status
    tmp="$PANE_STATUS_FILE.tmp.$$"
    jq --arg p "$1" --arg s "$2" '.[$p] = $s' "$PANE_STATUS_FILE" > "$tmp" && mv "$tmp" "$PANE_STATUS_FILE"
}

# Returns success (0) if the given pane's visible viewport changes within a
# short poll window — our proxy for "the user is actively typing here or
# watching output stream in right now". `pane.output_changed` isn't a
# hookable plugin event and the `revision` counter doesn't bump for
# keystrokes on the current input line, so we diff the actual rendered
# content instead, which does reflect every keystroke.
pane_is_active() { # $1 pane_id
    local before after
    before=$("$HERDR" pane read "$1" --source visible --lines 8 2>/dev/null) || return 1
    sleep "$ACTIVITY_CHECK_SECONDS"
    after=$("$HERDR" pane read "$1" --source visible --lines 8 2>/dev/null) || return 1
    [ "$before" != "$after" ]
}

if [ "$agent_status" = "working" ]; then
    # --- A. Dispatch tracking ---
    sleep "$DEBOUNCE_SECONDS"
    current_status=$("$HERDR" agent get "$pane_id" 2>/dev/null | jq -r '.result.agent.agent_status // empty')
    if [ "$current_status" != "working" ]; then
        # Flickered back before settling; not a real dispatch.
        [ -n "$current_status" ] && remember_status "$pane_id" "$current_status"
        exit 0
    fi
    remember_status "$pane_id" "working"

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
    exit 0
fi

# --- B. Finish-focus ---
# Only meaningful if this pane was previously working and has now settled
# into something else (idle/done/blocked all mean "not working anymore").
if [ "$prev_status" = "working" ]; then
    sleep "$DEBOUNCE_SECONDS"
    current_status=$("$HERDR" agent get "$pane_id" 2>/dev/null | jq -r '.result.agent.agent_status // empty')
    if [ "$current_status" = "working" ]; then
        # Flickered back to working; not actually finished.
        remember_status "$pane_id" "working"
        exit 0
    fi
    [ -n "$current_status" ] && remember_status "$pane_id" "$current_status"

    focused_pane=$("$HERDR" pane list 2>/dev/null | jq -r '[.result.panes[] | select(.focused == true)][0].pane_id // empty')

    if [ "$focused_pane" = "$pane_id" ]; then
        # Already looking at it; nothing to do.
        exit 0
    fi

    if [ -n "$focused_pane" ] && pane_is_active "$focused_pane"; then
        # User appears to be actively typing/reading in their current pane
        # right now — do not steal focus out from under them.
        exit 0
    fi

    "$HERDR" agent focus "$pane_id" >/dev/null 2>&1 || true
    exit 0
fi

# Not a transition we care about (e.g. idle -> blocked, or first sighting);
# just remember the status for next time.
remember_status "$pane_id" "$agent_status"
