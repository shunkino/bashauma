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
LOCK_DIR="$STATE_DIR/state.lock"
LOCK_STALE_SECONDS="${BASHAUMA_LOCK_STALE_SECONDS:-30}"

command -v jq >/dev/null 2>&1 || exit 0

pane_id=$(printf '%s' "${HERDR_PLUGIN_EVENT_JSON:-}" | jq -r '.pane_id // .data.pane_id // empty' 2>/dev/null)
agent_status=$(printf '%s' "${HERDR_PLUGIN_EVENT_JSON:-}" | jq -r '.agent_status // .data.agent_status // empty' 2>/dev/null)

[ -n "$pane_id" ] || exit 0
[ -n "$agent_status" ] || exit 0

# The hook can run concurrently for several panes (many agents settle at
# once), and every state update below is a read-modify-write of a JSON file.
# `flock` isn't available on stock macOS, so use an atomic mkdir lock with a
# stale-lock escape hatch in case a previous run was killed mid-update.
lock_held=0

release_lock() {
    [ "$lock_held" = "1" ] || return 0
    lock_held=0
    rmdir "$LOCK_DIR" 2>/dev/null || true
}
trap release_lock EXIT

acquire_lock() {
    local waited=0 max_waits
    # 0.1s per attempt; after LOCK_STALE_SECONDS assume the holder died.
    max_waits=$(awk "BEGIN{printf \"%d\", $LOCK_STALE_SECONDS * 10}")
    while ! mkdir "$LOCK_DIR" 2>/dev/null; do
        waited=$((waited + 1))
        if [ "$waited" -ge "$max_waits" ]; then
            # Stale lock from a killed run — break it and take over.
            rmdir "$LOCK_DIR" 2>/dev/null || true
            mkdir "$LOCK_DIR" 2>/dev/null || return 1
            break
        fi
        sleep 0.1
    done
    lock_held=1
    return 0
}

read_json_file() { # $1 path, $2 default JSON
    if [ -s "$1" ] && jq -e . "$1" >/dev/null 2>&1; then
        cat "$1"
    else
        printf '%s\n' "$2"
    fi
}

write_json_file() { # $1 path, $2 JSON content
    local tmp="$1.tmp.$$"
    printf '%s\n' "$2" > "$tmp" && mv "$tmp" "$1"
}

# Per-pane last-known status, pruned to panes that are still open so the file
# doesn't grow without bound over a long session.
remember_status() { # $1 pane_id, $2 status, $3 (optional) JSON array of open pane ids
    local current updated
    acquire_lock || return 0
    current=$(read_json_file "$PANE_STATUS_FILE" '{}')
    if [ -n "${3:-}" ]; then
        updated=$(printf '%s' "$current" | jq -c --arg p "$1" --arg s "$2" --argjson open "$3" \
            '(.[$p] = $s) | with_entries(select(.key as $k | $open | index($k) != null))' 2>/dev/null || true)
    else
        updated=$(printf '%s' "$current" | jq -c --arg p "$1" --arg s "$2" '.[$p] = $s' 2>/dev/null || true)
    fi
    [ -n "$updated" ] && write_json_file "$PANE_STATUS_FILE" "$updated"
    release_lock
    return 0
}

# Open agent panes, in the order agent.list reports them (creation/tab order)
# — also the deterministic redirect order. Empty array if herdr is unreachable.
list_open_pane_ids() {
    "$HERDR" agent list 2>/dev/null | jq -c '[.result.agents[].pane_id]' 2>/dev/null || true
}

prev_status=$(read_json_file "$PANE_STATUS_FILE" '{}' | jq -r --arg p "$pane_id" '.[$p] // "unknown"')

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
    current_status=$({ "$HERDR" agent get "$pane_id" 2>/dev/null | jq -r '.result.agent.agent_status // empty'; } || true)
    if [ "$current_status" != "working" ]; then
        # Flickered back before settling; not a real dispatch.
        [ -n "$current_status" ] && remember_status "$pane_id" "$current_status"
        exit 0
    fi

    open_ids_json=$(list_open_pane_ids)
    if [ -z "$open_ids_json" ]; then
        # herdr unreachable / no agent list: don't touch round state.
        remember_status "$pane_id" "working"
        exit 0
    fi

    remember_status "$pane_id" "working" "$open_ids_json"

    acquire_lock || exit 0

    # Mark this pane done, then drop any done pane_id that is no longer open
    # (agent exited / pane closed) so it can't block round completion forever.
    done_ids_json=$(read_json_file "$STATE_FILE" '{"round_done_pane_ids":[]}' \
        | jq -c --arg pane "$pane_id" --argjson open "$open_ids_json" \
            '((.round_done_pane_ids // []) + [$pane]) | unique | map(select(. as $p | $open | index($p) != null))' 2>/dev/null || true)
    if [ -z "$done_ids_json" ]; then
        release_lock
        exit 0
    fi

    open_count=$(printf '%s' "$open_ids_json" | jq 'length')
    done_count=$(printf '%s' "$done_ids_json" | jq 'length')

    if [ "$open_count" -gt 0 ] && [ "$open_count" -eq "$done_count" ]; then
        # Round complete: every open pane has received a task this round.
        write_json_file "$STATE_FILE" '{"round_done_pane_ids":[]}'
        release_lock
        "$HERDR" plugin pane open --plugin "$PLUGIN_ID" --entrypoint winner --focus >/dev/null 2>&1 || true
        exit 0
    fi

    write_json_file "$STATE_FILE" "{\"round_done_pane_ids\":$done_ids_json}"
    release_lock

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
    current_status=$({ "$HERDR" agent get "$pane_id" 2>/dev/null | jq -r '.result.agent.agent_status // empty'; } || true)
    if [ "$current_status" = "working" ]; then
        # Flickered back to working; not actually finished.
        remember_status "$pane_id" "working"
        exit 0
    fi
    [ -n "$current_status" ] && remember_status "$pane_id" "$current_status" "$(list_open_pane_ids)"

    focused_pane=$({ "$HERDR" pane list 2>/dev/null | jq -r '[.result.panes[] | select(.focused == true)][0].pane_id // empty'; } || true)

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
remember_status "$pane_id" "$agent_status" "$(list_open_pane_ids)"
