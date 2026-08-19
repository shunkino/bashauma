#!/bin/bash
# bashauma: dispatch-yield entrypoint (prd.md §6.1.1).
#
# Fired by herdr for every `pane.agent_status_changed` event. Only a
# transition INTO `working` is a dispatch yield -- it schedules the ready
# queue and moves focus. Every other transition (working -> idle/done/
# blocked, or any other status change) just records the pane's status for
# the next yield and returns; it must NEVER move focus (prd.md §6.5 -- the
# hard invariant of §9, and exactly the v0.1 "finish-focus" bug removed in
# this revision).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/state.sh
. "$SCRIPT_DIR/lib/state.sh"
# shellcheck source=lib/config.sh
. "$SCRIPT_DIR/lib/config.sh"
# shellcheck source=lib/scheduler.sh
. "$SCRIPT_DIR/lib/scheduler.sh"

if ! command -v jq >/dev/null 2>&1; then
    echo "bashauma: jq is required but was not found on PATH" >&2
    exit 0
fi

trap state_release_lock EXIT

DEBOUNCE_SECONDS="${BASHAUMA_DEBOUNCE_SECONDS:-1.5}"

pane_id=$(printf '%s' "${HERDR_PLUGIN_EVENT_JSON:-}" | jq -r '.pane_id // .data.pane_id // empty' 2>/dev/null || true)
agent_status=$(printf '%s' "${HERDR_PLUGIN_EVENT_JSON:-}" | jq -r '.agent_status // .data.agent_status // empty' 2>/dev/null || true)

[ -n "$pane_id" ] || exit 0
[ -n "$agent_status" ] || exit 0

if [ "$agent_status" != "working" ]; then
    record_status "$pane_id" "$agent_status"
    exit 0
fi

# mode = off disables automatic (dispatch-triggered) scheduling, but the
# `next` action stays fully functional (prd.md §6.8). Check this BEFORE
# paying the debounce sleep + `agent get` re-verification round-trip below
# (Hockney's nit): every `-> working` transition otherwise ate that ~1.5s
# cost even though the outcome -- no scheduling -- was already decided.
config_load
if [ "$CONFIG_MODE" = "off" ]; then
    exit 0
fi

# Flicker filtering (prd.md §6.6): some agents (e.g. Copilot CLI opening/
# closing its "tasks" sub-view) briefly flip status and back with no real
# dispatch behind it. Debounce, then re-verify with `agent get` before
# treating this as a real yield.
sleep "$DEBOUNCE_SECONDS"
current_status=$("$HERDR_CMD" agent get "$pane_id" 2>/dev/null | jq -r '.result.agent.agent_status // empty' 2>/dev/null || true)

# KNOWN GAP (Hockney review, minor #6, deferred): a *transient* `agent get`
# failure here (herdr momentarily unreachable, not the pane actually having
# flickered) is indistinguishable from "flickered back" below --
# current_status is empty either way, so a genuine dispatch can be
# silently dropped with no retry. Not fixed in this revision: prd.md §10's
# "never guess" principle argues against inventing a retry/backoff policy
# it doesn't specify, and a spurious retry here risks double-scheduling if
# the first `agent get` actually succeeded server-side but the response
# was lost. Left as explicit follow-up for Keaton/Fenster + a prd.md note,
# not silently worked around.
if [ "$current_status" != "working" ]; then
    # Flickered back before settling; not a real dispatch.
    if [ -n "$current_status" ]; then
        record_status "$pane_id" "$current_status"
    fi
    exit 0
fi

record_status "$pane_id" "working"

schedule "$pane_id"
