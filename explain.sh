#!/bin/bash
# bashauma: read-only `explain` action entrypoint (design doc item 1 --
# .squad/design/v1.1-scheduling.md, "Revised recommended order").
#
# Reports why the scheduler would pick what it picks for the current
# departure pane, by calling lib/scheduler.sh's explain_decision(), which
# runs the exact same _classify_candidate/_affinity_rank/
# _workspace_locality_rank/_lineage_trusted cascade schedule() itself
# calls -- not a second copy of the cascade that could drift from the
# real one.
#
# HARD REQUIREMENT: this action must NEVER move focus (never invoke the
# herdr focus-changing command). It is not a third yield point alongside
# on_status_changed.sh's dispatch yield and next.sh's explicit yield
# (prd.md §9) -- explain_decision() never acquires the state lock and
# never calls state_save, so even though it runs classification logic
# that can compute a hypothetical false-claim demotion or lineage-forget,
# none of that is ever persisted to state.json here, let alone acted on
# by moving focus. Deliberately no
# `trap state_release_lock EXIT` (unlike next.sh/on_status_changed.sh):
# this script never acquires the lock in the first place.
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

departure_pane_id=$(printf '%s' "${HERDR_PLUGIN_CONTEXT_JSON:-}" | jq -r '.focused_pane_id // empty' 2>/dev/null || true)

if [ -z "$departure_pane_id" ]; then
    # Same agent-list-based fallback next.sh uses for callers (including
    # the test harness's invoke_next-style helpers) that don't set
    # HERDR_PLUGIN_CONTEXT_JSON.
    departure_pane_id=$("$HERDR_CMD" agent list 2>/dev/null | jq -r '[.result.agents[] | select(.focused == true)][0].pane_id // empty' 2>/dev/null || true)
fi

if [ -z "$departure_pane_id" ]; then
    echo "bashauma: explain: could not determine the current pane (no focused_pane_id in context, no focused agent in agent list)" >&2
    exit 0
fi

explain_decision "$departure_pane_id"
