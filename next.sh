#!/bin/bash
# bashauma: explicit-yield entrypoint (prd.md §6.1.2 -- the `next` action).
#
# Invoked when the user presses their bound key (there is no
# `[[keybindings]]` table in herdr-plugin.toml -- the user binds this
# themselves via `[[keys.command]]` in their own herdr config; see
# README.md). This IS sched_yield(): "I'm done here, give me the next
# runnable pane."
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

departure_pane_id=$(printf '%s' "${HERDR_PLUGIN_CONTEXT_JSON:-}" | jq -r '.focused_pane_id // empty' 2>/dev/null || true)

if [ -z "$departure_pane_id" ]; then
    # HERDR_PLUGIN_CONTEXT_JSON should always carry focused_pane_id when
    # herdr invokes this for real; fall back to asking `agent list` which
    # pane is focused (also what the test harness's invoke_next exercises,
    # since it doesn't set the context env var).
    departure_pane_id=$("$HERDR_CMD" agent list 2>/dev/null | jq -r '[.result.agents[] | select(.focused == true)][0].pane_id // empty' 2>/dev/null || true)
fi

[ -n "$departure_pane_id" ] || exit 0

schedule "$departure_pane_id"
