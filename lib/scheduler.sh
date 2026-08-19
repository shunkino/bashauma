#!/bin/bash
# bashauma: pick-next scheduler core (prd.md §6.2-§6.4).
#
# Sourced by on_status_changed.sh (dispatch yield) and next.sh (explicit
# yield), after lib/state.sh and lib/config.sh. Exposes:
#
#   record_status <pane_id> <status>  -- non-dispatch bookkeeping (§6.5)
#   schedule <departure_pane_id>      -- the pick-next algorithm (§6.4)
#
# Both entrypoints must `trap state_release_lock EXIT` themselves so a
# killed run cannot wedge the lock past its own process lifetime (beyond
# the stale-lock escape hatch in lib/state.sh).

HERDR_CMD="${HERDR_BIN_PATH:-herdr}"
PLUGIN_ID="bashauma"

# _now_ms
# Milliseconds since epoch. Aging (§6.4) and false-claim demotion are
# exercised by tests at sub-second resolution, so whole-second `date +%s`
# isn't precise enough -- but `%N` isn't portable (classic BSD date lacks
# it). Try, in order: bash 5+'s $EPOCHREALTIME, `date +%s%N` (works on GNU
# date and on newer BSD/macOS date builds that do support %N), then
# python3/perl HiRes, then fall back to whole-second precision.
_now_ms() {
    if [ -n "${EPOCHREALTIME:-}" ]; then
        awk -v t="$EPOCHREALTIME" 'BEGIN{printf "%d", t*1000}'
        return
    fi
    local ns
    ns=$(date +%s%N 2>/dev/null)
    case "$ns" in
    *[!0-9]* | '')
        if command -v python3 >/dev/null 2>&1; then
            python3 -c 'import time; print(int(time.time() * 1000))'
        elif command -v perl >/dev/null 2>&1; then
            perl -MTime::HiRes=time -e 'printf("%d\n", time() * 1000)'
        else
            echo $(($(date +%s) * 1000))
        fi
        ;;
    *)
        awk -v ns="$ns" 'BEGIN{printf "%d", ns/1000000}'
        ;;
    esac
}

# agent_list_json
# Prints the raw `.result.agents` JSON array on stdout. Returns non-zero
# (printing nothing) if herdr is unreachable or the response is malformed
# (prd.md §10: "leave all state untouched and do nothing. Never guess.").
agent_list_json() {
    local raw
    if ! raw=$("$HERDR_CMD" agent list 2>/dev/null); then
        return 1
    fi
    if ! printf '%s' "$raw" | jq -e '.result.agents' >/dev/null 2>&1; then
        return 1
    fi
    printf '%s' "$raw" | jq -c '.result.agents'
}

# confirm_p0 <pane_id>
# Bottom-anchored blocked-confirmation check (prd.md §6.2): true only if
# the bottom CONFIG_BLOCKED_CONFIRM_LINES non-empty lines of the pane's
# visible viewport match CONFIG_BLOCKED_CONFIRM_PATTERN.
#
# `grep -Eqe -- "$pattern"` (not bare `grep -Eq "$pattern"`): a
# user-configured blocked_confirm_pattern beginning with `-` would
# otherwise be parsed as a grep option, not a regex (Rai, option-injection
# finding). `-e` pins the argument as a pattern unconditionally. A
# malformed regex still just makes grep exit non-zero here -- confirm_p0
# returns failure, the caller demotes the candidate to P1 -- it never
# crashes the surrounding `set -e` script, since this call is always used
# as an `if`/`elif` condition.
confirm_p0() {
    local pane_id="$1" text bottom
    text=$("$HERDR_CMD" pane read "$pane_id" --source visible 2>/dev/null) || return 1
    bottom=$(printf '%s\n' "$text" | awk 'NF' | tail -n "${CONFIG_BLOCKED_CONFIRM_LINES:-5}")
    printf '%s' "$bottom" | grep -Eqe "$CONFIG_BLOCKED_CONFIRM_PATTERN" 2>/dev/null
}

# _affinity_rank <tab> <ws> <cwd> <dep_tab> <dep_ws> <dep_cwd>
# Lower is closer. Respects CONFIG_AFFINITY (prd.md §6.4, §6.8):
#   tab (default) -> tab_id > workspace_id > cwd > none
#   workspace     -> workspace_id > cwd > none (tab_id never distinguished)
#   none          -> affinity plays no role (always rank 0)
_affinity_rank() {
    local tab="$1" ws="$2" cwd="$3" dep_tab="$4" dep_ws="$5" dep_cwd="$6"
    case "$CONFIG_AFFINITY" in
    none)
        echo 0
        ;;
    workspace)
        if [ -n "$ws" ] && [ "$ws" = "$dep_ws" ]; then
            echo 0
        elif [ -n "$cwd" ] && [ "$cwd" = "$dep_cwd" ]; then
            echo 1
        else
            echo 2
        fi
        ;;
    *)
        if [ -n "$tab" ] && [ "$tab" = "$dep_tab" ]; then
            echo 0
        elif [ -n "$ws" ] && [ "$ws" = "$dep_ws" ]; then
            echo 1
        elif [ -n "$cwd" ] && [ "$cwd" = "$dep_cwd" ]; then
            echo 2
        else
            echo 3
        fi
        ;;
    esac
}

# record_status <pane_id> <status>
# Non-dispatch status bookkeeping (prd.md §6.5): remember the pane's
# status, and seed (never move focus for) its queue-entry timestamp the
# first time it becomes runnable. Locks its own read-modify-write, so it's
# safe to call standalone (outside schedule()'s lock).
record_status() {
    local pane_id="$1" status="$2" state now_ms
    state_acquire_lock || return 0
    state=$(state_load)
    now_ms=$(_now_ms)
    case "$status" in
    idle | done | blocked)
        state=$(printf '%s' "$state" | jq -c --arg p "$pane_id" --arg s "$status" --argjson now "$now_ms" \
            '.pane_status[$p] = $s | .first_runnable_at[$p] //= $now')
        ;;
    *)
        state=$(printf '%s' "$state" | jq -c --arg p "$pane_id" --arg s "$status" \
            '.pane_status[$p] = $s | del(.first_runnable_at[$p])')
        ;;
    esac
    state_save "$state"
    state_release_lock
}

# _demote_pane_to_p1 <state json> <pane_id> <now_ms>
# Shared false-claim-demotion bookkeeping (prd.md §6.4), used both when the
# *previous* P0 winner left `blocked` without dispatching, and when a
# candidate fails its P0 confirmation this yield. Prints the updated state
# JSON on stdout. The demoted pane's P1 queue-entry clock
# (`first_runnable_at`) resets to `now_ms`: aging measures "how long has
# this P1 entry been waiting", and a demotion logically begins a fresh P1
# entry, not a continuation of whatever clock it had under a different
# class. After CONFIG_P0_SUPPRESS_AFTER_DEMOTIONS cumulative demotions
# (default 3, named here rather than left as a magic number -- Hockney's
# nit -- and exposed as the `p0_suppress_after_demotions` config key), the
# pane is permanently p0_suppressed and stops being considered for P0 at
# all, per prd.md's "repeated demotions... suppress its P0 eligibility
# entirely."
_demote_pane_to_p1() {
    local in_state="$1" pane_id="$2" now_ms="$3"
    printf '%s' "$in_state" | jq -c --arg p "$pane_id" --argjson now "$now_ms" \
        --argjson threshold "${CONFIG_P0_SUPPRESS_AFTER_DEMOTIONS:-3}" '
        .demotion_count[$p] = ((.demotion_count[$p] // 0) + 1) |
        .p0_demoted_pane_ids = ((.p0_demoted_pane_ids // []) + [$p] | unique) |
        .first_runnable_at[$p] = $now |
        if (.demotion_count[$p] >= $threshold) then .p0_suppressed_pane_ids = ((.p0_suppressed_pane_ids // []) + [$p] | unique) else . end
    '
}

# schedule <departure_pane_id>
# The pick-next algorithm (prd.md §6.2-§6.4).
#
# Locking strategy (regression: tests/cases/regression_lock_scope.sh --
# BLOCKER #1 in Hockney's rejected review): all *external* herdr I/O
# (`agent list`, and one `pane read` per blocked candidate needing a §6.2
# confirmation) happens BEFORE the state lock is ever acquired. The lock
# is taken only around the local, fast, read-modify-write of state.json
# (prune/demote/classify/pick/save), then released before the final
# `agent focus` call. This keeps the lock's actual held duration bounded
# and independent of herdr's response latency, so
# STATE_LOCK_STALE_SECONDS's stale-holder assumption (lib/state.sh) stays
# valid: a lock held past the timeout really does mean the holder is dead,
# not just "still waiting on a slow `pane read`".
#
# Since the P0-confirmation reads happen before the lock, they're taken
# against an unlocked *pre-lock snapshot* of state (safe to read without
# the lock -- see lib/state.sh's state_load comment) purely to decide
# which blocked candidates even need a confirmation read (already fed/
# demoted/suppressed ones don't). That snapshot can be stale by the time
# the real lock is held below, so every decision it fed is re-validated
# against the authoritative, freshly-locked state: is_fed/is_suppressed/
# is_demoted are re-checked from scratch in the candidate loop, and if a
# blocked candidate needs a confirmation this schedule() call couldn't
# have anticipated (not in the pre-lock cache), it is fetched directly at
# that point as a rare fallback -- still correct, just not covered by the
# lock-scope regression's happy path.
schedule() {
    local departure_pane_id="$1"
    local agents_json open_ids_json open_count state now_ms

    config_load

    # --- Phase 1 (no lock): snapshot herdr's world view ---------------------
    if ! agents_json=$(agent_list_json); then
        # herdr unreachable / bad response: touch nothing (prd.md §10). No
        # lock was ever taken here, so there is nothing to release either.
        return 0
    fi

    now_ms=$(_now_ms)
    open_ids_json=$(printf '%s' "$agents_json" | jq -c '[.[].pane_id]')
    open_count=$(printf '%s' "$open_ids_json" | jq 'length')

    # --- Phase 2 (no lock): pre-fetch P0 confirmations ----------------------
    # Build a pane_id -> confirmed(true/false) map for every candidate that
    # (per this unlocked snapshot) looks like it will need one, so the
    # slow `pane read` round-trips happen before we ever take the lock.
    local prelock_state confirm_cache="{}"
    local agent_obj pane_id status is_parked is_fed is_suppressed is_demoted confirmed
    prelock_state=$(state_load)
    while IFS= read -r agent_obj; do
        [ -n "$agent_obj" ] || continue
        status=$(printf '%s' "$agent_obj" | jq -r '.agent_status')
        [ "$status" = "blocked" ] || continue
        pane_id=$(printf '%s' "$agent_obj" | jq -r '.pane_id')

        is_parked=$(printf '%s' "$CONFIG_PARKED_PANES_JSON" | jq --arg p "$pane_id" 'index($p) != null')
        [ "$is_parked" != "true" ] || continue

        is_fed=$(printf '%s' "$prelock_state" | jq -r --arg p "$pane_id" '(.epoch_fed_pane_ids // []) | index($p) != null')
        [ "$is_fed" != "true" ] || continue

        is_suppressed=$(printf '%s' "$prelock_state" | jq -r --arg p "$pane_id" '(.p0_suppressed_pane_ids // []) | index($p) != null')
        is_demoted=$(printf '%s' "$prelock_state" | jq -r --arg p "$pane_id" '(.p0_demoted_pane_ids // []) | index($p) != null')
        if [ "$is_suppressed" = "true" ] || [ "$is_demoted" = "true" ]; then
            continue
        fi

        if [ "$CONFIG_BLOCKED_CONFIRM" = "false" ]; then
            continue
        fi
        if confirm_p0 "$pane_id"; then
            confirmed="true"
        else
            confirmed="false"
        fi
        confirm_cache=$(printf '%s' "$confirm_cache" | jq -c --arg p "$pane_id" --argjson ok "$confirmed" '. + {($p): $ok}')
    done < <(printf '%s' "$agents_json" | jq -c '.[]')

    # --- Phase 3 (locked): the actual state.json read-modify-write ---------
    state_acquire_lock || return 0

    state=$(state_load)


    # --- prune closed panes from epoch-scoped state (§6.3) ------------------
    state=$(printf '%s' "$state" | jq -c --argjson open "$open_ids_json" '
        .epoch_fed_pane_ids = ((.epoch_fed_pane_ids // []) | map(select(. as $p | $open | index($p) != null))) |
        .pane_status = ((.pane_status // {}) | with_entries(select(.key as $k | $open | index($k) != null))) |
        .first_runnable_at = ((.first_runnable_at // {}) | with_entries(select(.key as $k | $open | index($k) != null))) |
        .p0_demoted_pane_ids = ((.p0_demoted_pane_ids // []) | map(select(. as $p | $open | index($p) != null)))
    ')

    # --- false-claim demotion (§6.4): the previous P0 winner left blocked, --
    # --- without dispatching -- the P0 claim was wrong.                    --
    local last_winner last_winner_was_p0 last_winner_status already_fed
    last_winner=$(printf '%s' "$state" | jq -r '.last_winner_pane_id // empty')
    last_winner_was_p0=$(printf '%s' "$state" | jq -r '.last_winner_was_p0 // false')
    if [ -n "$last_winner" ] && [ "$last_winner_was_p0" = "true" ]; then
        last_winner_status=$(printf '%s' "$agents_json" | jq -r --arg p "$last_winner" \
            '[.[] | select(.pane_id == $p)][0].agent_status // empty')
        already_fed=$(printf '%s' "$state" | jq -r --arg p "$last_winner" '(.epoch_fed_pane_ids // []) | index($p) != null')
        if [ "$last_winner_status" = "blocked" ] && [ "$already_fed" != "true" ]; then
            state=$(_demote_pane_to_p1 "$state" "$last_winner" "$now_ms")
        fi
    fi

    # --- mark the departure pane fed, if it is now dispatched ---------------
    local departure_status
    departure_status=$(printf '%s' "$agents_json" | jq -r --arg p "$departure_pane_id" \
        '[.[] | select(.pane_id == $p)][0].agent_status // empty')
    if [ "$departure_status" = "working" ]; then
        state=$(printf '%s' "$state" | jq -c --arg p "$departure_pane_id" \
            '.epoch_fed_pane_ids = ((.epoch_fed_pane_ids // []) + [$p] | unique)')
    fi

    # --- departure affinity anchors -----------------------------------------
    local dep_tab dep_ws dep_cwd
    dep_tab=$(printf '%s' "$agents_json" | jq -r --arg p "$departure_pane_id" '[.[] | select(.pane_id == $p)][0].tab_id // empty')
    dep_ws=$(printf '%s' "$agents_json" | jq -r --arg p "$departure_pane_id" '[.[] | select(.pane_id == $p)][0].workspace_id // empty')
    dep_cwd=$(printf '%s' "$agents_json" | jq -r --arg p "$departure_pane_id" '[.[] | select(.pane_id == $p)][0].cwd // empty')

    # --- build candidates ----------------------------------------------------
    # P0 confirmation needs one `pane read` per blocked candidate, so this
    # loop runs in bash (not pure jq).
    local candidates="[]"
    local agent_obj pane_id status tab_id workspace_id cwd seq
    local is_parked is_fed has_fra fra waited class aged affinity_rank
    local is_suppressed is_demoted aging_threshold_ms cached
    # CONFIG_AGING_SECONDS is coerced to a safe integer by lib/config.sh's
    # config_load (_config_to_int) before schedule() ever runs, so this
    # `$(( ))` can no longer see a fractional or non-numeric value crash
    # it (regression: tests/cases/regression_fractional_aging_seconds.sh).
    aging_threshold_ms=$((CONFIG_AGING_SECONDS * 1000))

    while IFS= read -r agent_obj; do
        [ -n "$agent_obj" ] || continue
        pane_id=$(printf '%s' "$agent_obj" | jq -r '.pane_id')
        status=$(printf '%s' "$agent_obj" | jq -r '.agent_status')
        tab_id=$(printf '%s' "$agent_obj" | jq -r '.tab_id // empty')
        workspace_id=$(printf '%s' "$agent_obj" | jq -r '.workspace_id // empty')
        cwd=$(printf '%s' "$agent_obj" | jq -r '.cwd // empty')
        seq=$(printf '%s' "$agent_obj" | jq -r '.state_change_seq // 0')

        is_parked=$(printf '%s' "$CONFIG_PARKED_PANES_JSON" | jq --arg p "$pane_id" 'index($p) != null')
        if [ "$is_parked" = "true" ]; then
            continue
        fi
        if [ "$status" = "working" ]; then
            continue
        fi

        is_fed=$(printf '%s' "$state" | jq -r --arg p "$pane_id" '(.epoch_fed_pane_ids // []) | index($p) != null')
        if [ "$is_fed" = "true" ]; then
            continue
        fi

        has_fra=$(printf '%s' "$state" | jq -r --arg p "$pane_id" '.first_runnable_at | has($p)')
        if [ "$has_fra" != "true" ]; then
            state=$(printf '%s' "$state" | jq -c --arg p "$pane_id" --argjson now "$now_ms" '.first_runnable_at[$p] = $now')
        fi
        fra=$(printf '%s' "$state" | jq -r --arg p "$pane_id" '.first_runnable_at[$p]')
        waited=$((now_ms - fra))

        class=""
        if [ "$status" = "blocked" ]; then
            is_suppressed=$(printf '%s' "$state" | jq -r --arg p "$pane_id" '(.p0_suppressed_pane_ids // []) | index($p) != null')
            is_demoted=$(printf '%s' "$state" | jq -r --arg p "$pane_id" '(.p0_demoted_pane_ids // []) | index($p) != null')
            if [ "$is_suppressed" = "true" ] || [ "$is_demoted" = "true" ]; then
                class="P1"
            elif [ "$CONFIG_BLOCKED_CONFIRM" = "false" ]; then
                class="P0"
            else
                # Use the pre-lock confirmation cache (Phase 2) if this
                # pane was covered by it; only fall back to a direct,
                # in-lock `pane read` for the rare case where the
                # authoritative (locked) state disagrees with the
                # pre-lock snapshot enough that this pane wasn't
                # anticipated as needing confirmation (e.g. another
                # process cleared its fed/demoted/suppressed flag between
                # the snapshot and this lock). That fallback keeps
                # correctness even under a race; it just isn't covered by
                # the lock-scope regression's happy path.
                cached=$(printf '%s' "$confirm_cache" | jq -r --arg p "$pane_id" '.[$p] // empty')
                if [ -z "$cached" ]; then
                    if confirm_p0 "$pane_id"; then
                        cached="true"
                    else
                        cached="false"
                    fi
                fi
                if [ "$cached" = "true" ]; then
                    class="P0"
                else
                    state=$(_demote_pane_to_p1 "$state" "$pane_id" "$now_ms")
                    fra="$now_ms"
                    waited=0
                    class="P1"
                fi
            fi
        elif [ "$status" = "idle" ] || [ "$status" = "done" ]; then
            class="P1"
        else
            # Unknown status -- never guess (prd.md §10).
            continue
        fi

        affinity_rank=$(_affinity_rank "$tab_id" "$workspace_id" "$cwd" "$dep_tab" "$dep_ws" "$dep_cwd")
        aged="false"
        if [ "$class" = "P1" ] && [ "$waited" -gt "$aging_threshold_ms" ]; then
            aged="true"
        fi

        candidates=$(printf '%s' "$candidates" | jq -c --arg pane "$pane_id" --arg class "$class" \
            --argjson aged "$aged" --argjson rank "$affinity_rank" --argjson seq "$seq" \
            '. + [{pane_id: $pane, class: $class, aged: $aged, affinity_rank: $rank, seq: $seq}]')
    done < <(printf '%s' "$agents_json" | jq -c '.[]')

    local winner_pane_id winner_class
    # Final `.pane_id` key makes the sort provably total (Hockney's nit):
    # without it, two candidates tying on every other key (aged_rank,
    # class_rank, affinity_rank, seq) fall back to jq's sort stability +
    # `agent list`'s emission order, which prd.md §6.4 doesn't actually
    # guarantee is deterministic across herdr versions/backends.
    winner_pane_id=$(printf '%s' "$candidates" | jq -r '
        map(. + {class_rank: (if .class == "P0" then 0 else 1 end), aged_rank: (if .aged then 0 else 1 end)}) |
        sort_by([.aged_rank, .class_rank, .affinity_rank, .seq, .pane_id]) |
        .[0].pane_id // empty
    ')

    if [ -z "$winner_pane_id" ]; then
        # Runnable set empty -> epoch drains (prd.md §6.3, §8).
        local winner_fired_epoch
        winner_fired_epoch=$(printf '%s' "$state" | jq -r '.winner_fired_epoch // false')
        local should_fire="false"
        if [ "$winner_fired_epoch" != "true" ] && [ "$open_count" -gt 0 ]; then
            should_fire="true"
            state=$(printf '%s' "$state" | jq -c '.winner_fired_epoch = true')
        fi
        state=$(printf '%s' "$state" | jq -c '.epoch_fed_pane_ids = [] | .p0_demoted_pane_ids = []')
        state_save "$state"
        state_release_lock

        if [ "$should_fire" = "true" ]; then
            # Tolerate ui_busy (another modal open): skip silently, still
            # counted as fired (prd.md §8).
            "$HERDR_CMD" plugin pane open --plugin "$PLUGIN_ID" --entrypoint winner --focus >/dev/null 2>&1 || true
        fi
        return 0
    fi

    winner_class=$(printf '%s' "$candidates" | jq -r --arg p "$winner_pane_id" '[.[] | select(.pane_id == $p)][0].class // empty')
    local winner_is_p0="false"
    if [ "$winner_class" = "P0" ]; then
        winner_is_p0="true"
    fi

    state=$(printf '%s' "$state" | jq -c --arg p "$winner_pane_id" --argjson is_p0 "$winner_is_p0" \
        '.winner_fired_epoch = false | .last_winner_pane_id = $p | .last_winner_was_p0 = $is_p0')

    state_save "$state"
    state_release_lock

    "$HERDR_CMD" agent focus "$winner_pane_id" >/dev/null 2>&1 || true
    return 0
}
