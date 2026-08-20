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

# _workspace_locality_rank <candidate_workspace_id> <dep_ws>
# B-lite (design doc "Revised recommended order" item 3 / "Response to the
# Devil's Advocate brief" §1-2): a 5th, purely lexicographic tier -- 0 if
# the candidate shares workspace_id with the departure pane, 1 otherwise.
# Inserted between affinity_rank and seq in the final sort_by below.
# Deliberately a hard gate, not a weighted score: since sort_by compares
# keys left-to-right, aged_rank/class_rank/affinity_rank (all compared
# first) already decide any case where a P0 candidate, an aged P1, or a
# closer-affinity candidate exists, so this tier can only ever break a tie
# among candidates that survive all three -- exactly "nothing is blocked,
# prefer the workspace the user was already in" (Shun's original example),
# never a P1-over-P0 or near-over-far affinity swing. No config, no state:
# purely a function of this yield's already-available agents_json/
# departure anchors, so it costs nothing and cannot regress determinism
# (prd.md §6.4) -- it is exactly as reproducible, and exactly as
# *predictable*, as every existing tier, per Keaton's concession that
# predictability, not mere reproducibility, is the real requirement.
_workspace_locality_rank() {
    local ws="$1" dep_ws="$2"
    if [ -n "$ws" ] && [ -n "$dep_ws" ] && [ "$ws" = "$dep_ws" ]; then
        echo 0
    else
        echo 1
    fi
}

# _resolve_confirm <pane_id>
# The single P0-confirmation resolution path shared by schedule() and
# explain_decision(): if the caller has pre-populated $_CONFIRM_CACHE_JSON
# (schedule()'s Phase 2 pre-lock prefetch, see schedule()'s comment) with a
# value for this pane_id, use it; otherwise call confirm_p0 directly. This
# is exactly the "use the cache, else fall back to a direct read" logic
# schedule() always had inline -- pulled out so _classify_candidate (and
# therefore explain_decision) share the identical resolution rule instead
# of a second copy of it. explain_decision() never populates the cache
# (nothing to prefetch outside a lock-scope constraint that doesn't apply
# to a read-only path), so it always takes the direct confirm_p0 branch --
# still just one `pane read` per blocked candidate, same cost shape as
# schedule()'s in-lock fallback.
_CONFIRM_CACHE_JSON="{}"
_resolve_confirm() {
    local pane_id="$1" cached
    cached=$(printf '%s' "$_CONFIRM_CACHE_JSON" | jq -r --arg p "$pane_id" '.[$p] // empty')
    if [ -n "$cached" ]; then
        [ "$cached" = "true" ]
        return
    fi
    confirm_p0 "$pane_id"
}

# _classify_candidate <state json> <agent_obj json> <dep_tab> <dep_ws> <dep_cwd> <now_ms> <aging_threshold_ms> [<log_enabled>]
# THE cascade's per-candidate classification rule (prd.md §6.2-§6.4),
# extracted so schedule() (which persists the resulting state and may
# focus the winner) and explain_decision() (which never persists or
# focuses anything) run the *identical* logic -- not two copies that can
# drift apart. Prints one JSON object on stdout: {"state": <possibly
# updated state>, "candidate": <candidate object, or null if this agent
# isn't a runnable candidate this yield>}.
#
# Side effects visible only in the returned "state" (first_runnable_at
# seeding, a false-claim demotion via _demote_pane_to_p1, forgetting a
# stale pane's lineage via _forget_stale_pane) are the real classification
# rules, not incidental -- schedule() persists them (they're what makes
# the cascade stateful); explain_decision() discards its own copy after
# printing a report, so calling this function is still fully read-only
# from state.json's point of view when the caller never calls state_save.
#
# <log_enabled> (default "true"): passed straight through to
# _demote_pane_to_p1's own log_enabled gate (see that function's comment).
# schedule() always passes "true" (or omits it); explain_decision() always
# passes "false", so a hypothetical demotion this function computes for a
# read-only report can never emit A-0's threshold-crossing log for a
# demotion that was never actually persisted.
_classify_candidate() {
    local state="$1" agent_obj="$2" dep_tab="$3" dep_ws="$4" dep_cwd="$5"
    local now_ms="$6" aging_threshold_ms="$7" log_enabled="${8:-true}"
    local pane_id status tab_id workspace_id cwd seq
    pane_id=$(printf '%s' "$agent_obj" | jq -r '.pane_id')
    status=$(printf '%s' "$agent_obj" | jq -r '.agent_status')
    tab_id=$(printf '%s' "$agent_obj" | jq -r '.tab_id // empty')
    workspace_id=$(printf '%s' "$agent_obj" | jq -r '.workspace_id // empty')
    cwd=$(printf '%s' "$agent_obj" | jq -r '.cwd // empty')
    seq=$(printf '%s' "$agent_obj" | jq -r '.state_change_seq // 0')

    local is_parked is_fed has_fra fra waited class is_suppressed="false" is_demoted="false"

    is_parked=$(printf '%s' "$CONFIG_PARKED_PANES_JSON" | jq --arg p "$pane_id" 'index($p) != null')
    if [ "$is_parked" = "true" ] || [ "$status" = "working" ]; then
        jq -n --argjson state "$state" '{state: $state, candidate: null}'
        return
    fi

    is_fed=$(printf '%s' "$state" | jq -r --arg p "$pane_id" '(.epoch_fed_pane_ids // []) | index($p) != null')
    if [ "$is_fed" = "true" ]; then
        jq -n --argjson state "$state" '{state: $state, candidate: null}'
        return
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

        # GitHub issue #1's restart/ID-reuse gap: see _lineage_trusted()'s
        # comment. Identical to schedule()'s original inline check.
        if [ "$is_suppressed" = "true" ] || [ "$is_demoted" = "true" ]; then
            if [ "$(_lineage_trusted "$state" "$pane_id" "$seq")" != "true" ]; then
                state=$(_forget_stale_pane "$state" "$pane_id")
                is_suppressed="false"
                is_demoted="false"
            fi
        fi

        if [ "$is_suppressed" = "true" ] || [ "$is_demoted" = "true" ]; then
            class="P1"
        elif [ "$CONFIG_BLOCKED_CONFIRM" = "false" ]; then
            class="P0"
        else
            if _resolve_confirm "$pane_id"; then
                class="P0"
            else
                state=$(_demote_pane_to_p1 "$state" "$pane_id" "$now_ms" "$seq" "$log_enabled")
                fra="$now_ms"
                waited=0
                class="P1"
                is_demoted="true"
            fi
        fi
    elif [ "$status" = "idle" ] || [ "$status" = "done" ]; then
        class="P1"
    else
        # Unknown status -- never guess (prd.md §10).
        jq -n --argjson state "$state" '{state: $state, candidate: null}'
        return
    fi

    local affinity_rank aged wl_rank demotion_count
    affinity_rank=$(_affinity_rank "$tab_id" "$workspace_id" "$cwd" "$dep_tab" "$dep_ws" "$dep_cwd")
    wl_rank=$(_workspace_locality_rank "$workspace_id" "$dep_ws")
    aged="false"
    if [ "$class" = "P1" ] && [ "$waited" -gt "$aging_threshold_ms" ]; then
        aged="true"
    fi
    demotion_count=$(printf '%s' "$state" | jq -r --arg p "$pane_id" '.demotion_count[$p] // 0')

    local candidate
    candidate=$(jq -n --arg pane "$pane_id" --arg class "$class" --arg status "$status" \
        --argjson aged "$aged" --argjson waited "$waited" --argjson rank "$affinity_rank" --argjson seq "$seq" \
        --argjson wl "$wl_rank" --argjson suppressed "$is_suppressed" --argjson demoted "$is_demoted" \
        --argjson demotion_count "$demotion_count" \
        '{pane_id: $pane, class: $class, status: $status, aged: $aged, waited_ms: $waited,
          affinity_rank: $rank, workspace_locality_rank: $wl, seq: $seq,
          is_suppressed: $suppressed, is_demoted: $demoted, demotion_count: $demotion_count}')

    jq -n --argjson state "$state" --argjson candidate "$candidate" '{state: $state, candidate: $candidate}'
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

# _demote_pane_to_p1 <state json> <pane_id> <now_ms> <observed_seq> [<log_enabled>]
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
#
# Also stamps `demotion_seq[pane_id] = observed_seq` -- the `agent list`
# `state_change_seq` seen for this pane_id right now, at the moment this
# demotion is recorded. lib/scheduler.sh's _lineage_trusted() uses this to
# detect a herdr server restart recycling this same ID onto a different
# agent later (GitHub issue #1's restart/ID-reuse gap; see that function).
#
# <log_enabled> (default "true"): gates the A-0 threshold-crossing stderr
# log below. MUST be passed "false" by any caller whose resulting state is
# not actually going to be state_save()'d -- explain_decision() computes
# this exact same demotion for reporting purposes only and discards its
# copy of state, so logging "crossed P0 suppression threshold" from that
# path would be a false event: A-0's whole purpose is trustworthy evidence
# for whether issue #3's demotion decay is ever built, and a log line a
# read-only, repeat-safe `explain` call can fire on demand (with
# demotion_count in the real state.json never actually moving) is exactly
# the "crying wolf" failure that would disqualify it as evidence (Hockney
# review, MAJOR finding, tests/cases/a0_suppression_logging.sh Scenario D).
# schedule() (the only path that ever persists this state) always passes
# "true" (or omits the arg, since "true" is the default); explain_decision()
# always passes "false", both for its own direct false-claim-demotion check
# and via _classify_candidate's log_enabled passthrough.
_demote_pane_to_p1() {
    local in_state="$1" pane_id="$2" now_ms="$3" observed_seq="${4:-0}" log_enabled="${5:-true}"
    local threshold prior_count out_state
    threshold="${CONFIG_P0_SUPPRESS_AFTER_DEMOTIONS:-3}"
    prior_count=$(printf '%s' "$in_state" | jq -r --arg p "$pane_id" '.demotion_count[$p] // 0')
    out_state=$(printf '%s' "$in_state" | jq -c --arg p "$pane_id" --argjson now "$now_ms" --argjson seq "$observed_seq" \
        --argjson threshold "$threshold" '
        .demotion_count[$p] = ((.demotion_count[$p] // 0) + 1) |
        .p0_demoted_pane_ids = ((.p0_demoted_pane_ids // []) + [$p] | unique) |
        .first_runnable_at[$p] = $now |
        .demotion_seq[$p] = $seq |
        if (.demotion_count[$p] >= $threshold) then .p0_suppressed_pane_ids = ((.p0_suppressed_pane_ids // []) + [$p] | unique) else . end
    ')
    # A-0 (design doc "Revised recommended order" item 2): log the exact
    # moment a pane's demotion_count crosses CONFIG_P0_SUPPRESS_AFTER_DEMOTIONS
    # and becomes p0_suppressed for the first time -- a diagnostic-only
    # signal, no behavior/config/state-schema change. This is the evidence
    # gate issue #3 (demotion_count decay) is waiting on: nobody has
    # observed a real suppression event outlive continued real use yet,
    # so decay stays unbuilt (design doc, "Response to the Devil's
    # Advocate brief", item 4) until this log shows one. stderr is the
    # chosen channel, not a log file: it reuses the exact precedent
    # already shipped for config-coercion warnings (herdr captures hook
    # stderr per invocation, readable via `herdr plugin log list --plugin
    # bashauma`, decisions.md 2026-08-19T21:36:10) instead of introducing
    # a second log file this plugin would have to size/rotate itself.
    # Gated on log_enabled (see above) so a read-only, never-persisted
    # caller (explain_decision()) cannot make this fire on a demotion that
    # never actually happened.
    if [ "$log_enabled" = "true" ] && [ "$((prior_count + 1))" -ge "$threshold" ] && [ "$prior_count" -lt "$threshold" ]; then
        echo "bashauma: pane $pane_id crossed P0 suppression threshold ($threshold demotions) at ${now_ms}ms" >&2
    fi
    printf '%s' "$out_state"
}

# _lineage_trusted <state json> <pane_id> <observed_seq>
# Prints "true"/"false": whether pane_id's existing p0_suppressed_pane_ids/
# p0_demoted_pane_ids/demotion_count bookkeeping can be trusted to be
# about the SAME continuously-live pane observed at <observed_seq> right
# now, rather than a different, now-gone agent that used to hold this ID
# (GitHub issue #1, "the more serious half": Hockney's rejection of
# Fenster's presence-only close-pruning fix, proven by
# tests/cases/regression_id_recycle_suppression.sh).
#
# Why presence-based pruning alone cannot catch this: herdr allocates
# pane_id (`wN:pM`) from a per-workspace counter that is monotonic for the
# life of one running herdr server, but a server *restart* resets that
# counter while state.json -- a plain file under $HERDR_PLUGIN_STATE_DIR,
# untouched by the herdr process restarting -- keeps whatever suppression/
# demotion bookkeeping it had. A brand-new agent can be allocated a
# recycled ID that used to belong to a different, previously-suppressed,
# now-permanently-gone agent. Because that recycled ID is, by
# construction, never observed *absent* from `agent list` before it
# reappears, a prune predicate keyed on "is this ID currently absent?" can
# never remove its stale entry -- there is no schedule() call where the ID
# is seen both closed and about to be reused.
#
# `state_change_seq` closes this without any new herdr call, and without
# depending on internals (socket path, PID, server boot time) that aren't
# part of herdr's documented plugin-facing surface: it is already present
# on every `agent list` entry, and is monotonically non-decreasing for the
# same continuously-live agent (confirmed live against the real herdr
# 0.8.0-preview binary -- see
# .squad/decisions/inbox/keaton-id-recycle-fix.md for what was checked and
# why the alternatives were rejected). A pane_id's bookkeeping is trusted
# only if BOTH:
#   (a) a demotion_seq[pane_id] was actually recorded for it (a pane_id
#       carrying suppression/demotion state with NO recorded demotion_seq
#       predates this fix, or was seeded some other way, and cannot be
#       verified -- so it is NOT trusted), and
#   (b) the currently observed state_change_seq is >= that recorded value
#       (a LOWER observed seq than what was last seen is impossible for
#       the same live entity, and proves the ID was recycled).
# Both failure modes resolve to "not trusted", which fails toward
# forgiving a pane rather than permanently denying it P0 -- the worse
# mistake here is silently starving a genuinely blocked, user-facing agent
# forever (the bug this closes), not occasionally letting a pane re-earn
# its demotion budget one extra time.
_lineage_trusted() {
    local in_state="$1" pane_id="$2" observed_seq="$3" recorded
    recorded=$(printf '%s' "$in_state" | jq -r --arg p "$pane_id" '.demotion_seq[$p] // empty')
    if [ -z "$recorded" ]; then
        echo "false"
        return
    fi
    awk -v obs="$observed_seq" -v rec="$recorded" 'BEGIN {
        if ((obs + 0) >= (rec + 0)) { print "true" } else { print "false" }
    }'
}

# _forget_stale_pane <state json> <pane_id>
# Wipes pane_id's suppression/demotion bookkeeping entirely (used when
# _lineage_trusted says it cannot be trusted), so it is judged as a
# genuinely fresh candidate this yield -- per prd.md §6.2/§6.4 -- instead
# of inheriting a stranger's history.
_forget_stale_pane() {
    local in_state="$1" pane_id="$2"
    printf '%s' "$in_state" | jq -c --arg p "$pane_id" '
        .p0_suppressed_pane_ids = ((.p0_suppressed_pane_ids // []) | map(select(. != $p))) |
        .p0_demoted_pane_ids = ((.p0_demoted_pane_ids // []) | map(select(. != $p))) |
        .demotion_count = ((.demotion_count // {}) | with_entries(select(.key != $p))) |
        .demotion_seq = ((.demotion_seq // {}) | with_entries(select(.key != $p)))
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
    # Feeds _classify_candidate's/_resolve_confirm's shared cache lookup
    # (see _resolve_confirm's comment) -- this IS the "already prefetched"
    # branch; a cache miss there still falls back to a direct confirm_p0
    # read, same as before this refactor.
    _CONFIRM_CACHE_JSON="$confirm_cache"

    # --- Phase 3 (locked): the actual state.json read-modify-write ---------
    state_acquire_lock || return 0

    state=$(state_load)


    # --- prune closed panes from epoch-scoped state (§6.3) ------------------
    #
    # p0_suppressed_pane_ids and demotion_count (session-lifetime per §6.4,
    # "repeated demotions within a session suppress its P0 eligibility
    # entirely") are pruned here too, alongside the other four maps
    # (including the new demotion_seq, below). This bounds unbounded
    # state.json growth for pane IDs that close and stay closed -- pure
    # hygiene, and it is real: herdr allocates pane_id (`wN:pM`) from a
    # per-workspace monotonic counter that is never reused for the life of
    # one running herdr server session (confirmed empirically -- `herdr
    # pane list` on a long-running session shows gaps like p1,p2,p6,p8
    # where closed panes' numbers were skipped, never recycled), so a
    # closed pane's ID does not resurface as a *different* agent within
    # the same session just because it's absent from `agent list` once.
    #
    # IMPORTANT (GitHub issue #1's "more serious half" -- Hockney's
    # rejection of an earlier revision that claimed otherwise, proven by
    # tests/cases/regression_id_recycle_suppression.sh): this presence-
    # based prune does NOT, and structurally CANNOT, close the ID-reuse
    # gap across a herdr **server restart**. A restart resets each
    # workspace's pane_id counter while state.json -- a plain file,
    # untouched by the herdr process restarting -- keeps whatever
    # suppression/demotion bookkeeping it had. A recycled ID is, by
    # construction, never observed *absent* from `agent list` before it
    # reappears (that's what "recycled" means), so a prune predicate keyed
    # on absence can never remove its stale entry: there is no schedule()
    # call that ever sees the ID both closed and about to be reused. That
    # gap is closed separately, below, by _lineage_trusted()/
    # _forget_stale_pane() at classification time, using state_change_seq
    # as a durable per-pane fingerprint rather than mere agent-list
    # presence -- see _lineage_trusted()'s comment for the full mechanism
    # and why this prune step alone was never going to be enough.
    #
    # demotion_count is deliberately left purely monotonic (no time-based
    # decay) rather than "a pane that false-claimed twice hours ago isn't
    # obviously untrustworthy now": that's GitHub issue #3, a distinct,
    # still-open, orthogonal concern (decaying trust in a *verified-same*
    # long-lived pane over time) from this fix (verifying a pane_id refers
    # to the *same* pane at all before trusting its history) -- see
    # .squad/decisions/inbox/keaton-id-recycle-fix.md for why this
    # revision does not resolve or reshape issue #3.
    #
    # A-0 (design doc item 2): before pruning, snapshot which pane_ids are
    # currently p0_suppressed, so any of them that fall out of the open
    # set this pass can be logged below -- the other diagnostic half of
    # the suppression-evidence-gathering this cycle ships (see
    # _demote_pane_to_p1's threshold-crossing log for the first half).
    local suppressed_before_prune
    suppressed_before_prune=$(printf '%s' "$state" | jq -c '.p0_suppressed_pane_ids // []')
    state=$(printf '%s' "$state" | jq -c --argjson open "$open_ids_json" '
        .epoch_fed_pane_ids = ((.epoch_fed_pane_ids // []) | map(select(. as $p | $open | index($p) != null))) |
        .pane_status = ((.pane_status // {}) | with_entries(select(.key as $k | $open | index($k) != null))) |
        .first_runnable_at = ((.first_runnable_at // {}) | with_entries(select(.key as $k | $open | index($k) != null))) |
        .p0_demoted_pane_ids = ((.p0_demoted_pane_ids // []) | map(select(. as $p | $open | index($p) != null))) |
        .p0_suppressed_pane_ids = ((.p0_suppressed_pane_ids // []) | map(select(. as $p | $open | index($p) != null))) |
        .demotion_count = ((.demotion_count // {}) | with_entries(select(.key as $k | $open | index($k) != null))) |
        .demotion_seq = ((.demotion_seq // {}) | with_entries(select(.key as $k | $open | index($k) != null)))
    ')
    # A-0: log every suppressed pane_id that this pass just pruned because
    # its pane closed. stderr, same channel/rationale as the
    # threshold-crossing log above -- see that comment.
    local pruned_suppressed pid
    pruned_suppressed=$(jq -r -n --argjson before "$suppressed_before_prune" --argjson open "$open_ids_json" \
        '$before | map(select(. as $p | $open | index($p) == null)) | .[]')
    if [ -n "$pruned_suppressed" ]; then
        while IFS= read -r pid; do
            [ -n "$pid" ] || continue
            echo "bashauma: suppressed pane $pid pruned on close at ${now_ms}ms" >&2
        done <<<"$pruned_suppressed"
    fi


    # --- false-claim demotion (§6.4): the previous P0 winner left blocked, --
    # --- without dispatching -- the P0 claim was wrong.                    --
    local last_winner last_winner_was_p0 last_winner_status last_winner_seq already_fed
    last_winner=$(printf '%s' "$state" | jq -r '.last_winner_pane_id // empty')
    last_winner_was_p0=$(printf '%s' "$state" | jq -r '.last_winner_was_p0 // false')
    if [ -n "$last_winner" ] && [ "$last_winner_was_p0" = "true" ]; then
        last_winner_status=$(printf '%s' "$agents_json" | jq -r --arg p "$last_winner" \
            '[.[] | select(.pane_id == $p)][0].agent_status // empty')
        already_fed=$(printf '%s' "$state" | jq -r --arg p "$last_winner" '(.epoch_fed_pane_ids // []) | index($p) != null')
        if [ "$last_winner_status" = "blocked" ] && [ "$already_fed" != "true" ]; then
            last_winner_seq=$(printf '%s' "$agents_json" | jq -r --arg p "$last_winner" \
                '[.[] | select(.pane_id == $p)][0].state_change_seq // 0')
            state=$(_demote_pane_to_p1 "$state" "$last_winner" "$now_ms" "$last_winner_seq" "true")
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
    # loop runs in bash (not pure jq). Per-agent classification itself is
    # delegated to _classify_candidate -- the single shared cascade rule
    # explain_decision() also calls, so the two can never drift apart (see
    # that function's comment). log_enabled="true": this IS the real,
    # persisted path -- any A-0 threshold-crossing this loop computes is
    # real (see _demote_pane_to_p1's log_enabled comment).
    local candidates="[]"
    local agent_obj classify_result cand aging_threshold_ms
    # CONFIG_AGING_SECONDS is coerced to a safe integer by lib/config.sh's
    # config_load (_config_to_int) before schedule() ever runs, so this
    # `$(( ))` can no longer see a fractional or non-numeric value crash
    # it (regression: tests/cases/regression_fractional_aging_seconds.sh).
    aging_threshold_ms=$((CONFIG_AGING_SECONDS * 1000))

    while IFS= read -r agent_obj; do
        [ -n "$agent_obj" ] || continue
        classify_result=$(_classify_candidate "$state" "$agent_obj" "$dep_tab" "$dep_ws" "$dep_cwd" "$now_ms" "$aging_threshold_ms" "true")
        state=$(printf '%s' "$classify_result" | jq -c '.state')
        cand=$(printf '%s' "$classify_result" | jq -c '.candidate')
        if [ "$cand" != "null" ]; then
            candidates=$(printf '%s' "$candidates" | jq -c --argjson c "$cand" '. + [$c]')
        fi
    done < <(printf '%s' "$agents_json" | jq -c '.[]')

    local winner_pane_id winner_class
    # Final `.pane_id` key makes the sort provably total (Hockney's nit):
    # without it, two candidates tying on every other key (aged_rank,
    # class_rank, affinity_rank, workspace_locality_rank, seq) fall back to
    # jq's sort stability + `agent list`'s emission order, which prd.md
    # §6.4 doesn't actually guarantee is deterministic across herdr
    # versions/backends. workspace_locality_rank (B-lite, design doc item
    # 3) is the new 5th tier, inserted between affinity_rank and seq: a
    # hard lexicographic gate, not a weight, so it only ever breaks a tie
    # among candidates that already survived aged/class/affinity -- see
    # _workspace_locality_rank()'s comment.
    winner_pane_id=$(printf '%s' "$candidates" | jq -r '
        map(. + {class_rank: (if .class == "P0" then 0 else 1 end), aged_rank: (if .aged then 0 else 1 end)}) |
        sort_by([.aged_rank, .class_rank, .affinity_rank, .workspace_locality_rank, .seq, .pane_id]) |
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

# _print_explain_report <departure_pane_id> <dep_tab> <dep_ws> <dep_cwd> <ranked candidates json> <winner_pane_id>
# Pretty-prints explain_decision()'s ranked candidate list to stdout.
# Pure formatting, no classification logic here -- everything it prints
# was already decided by _classify_candidate/the sort_by in
# explain_decision(), never recomputed independently.
_print_explain_report() {
    local departure_pane_id="$1" dep_tab="$2" dep_ws="$3" dep_cwd="$4" ranked="$5" winner_pane_id="$6"
    local count

    printf 'bashauma explain -- departure pane: %s (tab=%s workspace=%s cwd=%s)\n' \
        "$departure_pane_id" "${dep_tab:-none}" "${dep_ws:-none}" "${dep_cwd:-none}"
    printf 'config: affinity=%s aging_seconds=%s blocked_confirm=%s p0_suppress_after_demotions=%s\n\n' \
        "$CONFIG_AFFINITY" "$CONFIG_AGING_SECONDS" "$CONFIG_BLOCKED_CONFIRM" "$CONFIG_P0_SUPPRESS_AFTER_DEMOTIONS"

    count=$(printf '%s' "$ranked" | jq 'length')
    if [ "$count" = "0" ]; then
        echo "no runnable candidates this yield -- the epoch would drain (prd.md §6.3, §8)."
        return 0
    fi

    echo "candidates, ranked by the real cascade (aged_rank, class_rank, affinity_rank, workspace_locality_rank, seq, pane_id) -- winner first:"
    local i=0 row pane class status aged waited rank wl seq suppressed demoted dcount marker
    while IFS= read -r row; do
        i=$((i + 1))
        pane=$(printf '%s' "$row" | jq -r '.pane_id')
        class=$(printf '%s' "$row" | jq -r '.class')
        status=$(printf '%s' "$row" | jq -r '.status')
        aged=$(printf '%s' "$row" | jq -r '.aged')
        waited=$(printf '%s' "$row" | jq -r '.waited_ms')
        rank=$(printf '%s' "$row" | jq -r '.affinity_rank')
        wl=$(printf '%s' "$row" | jq -r '.workspace_locality_rank')
        seq=$(printf '%s' "$row" | jq -r '.seq')
        suppressed=$(printf '%s' "$row" | jq -r '.is_suppressed')
        demoted=$(printf '%s' "$row" | jq -r '.is_demoted')
        dcount=$(printf '%s' "$row" | jq -r '.demotion_count')
        marker=""
        if [ "$pane" = "$winner_pane_id" ]; then
            marker="  <-- WINNER"
        fi
        printf '  %d. %s (raw_status=%s)%s\n' "$i" "$pane" "$status" "$marker"
        printf '       class=%s  affinity_rank=%s  aged=%s  waited_ms=%s  workspace_locality_rank=%s\n' \
            "$class" "$rank" "$aged" "$waited" "$wl"
        printf '       state_change_seq=%s  suppressed=%s  demoted=%s  demotion_count=%s\n' \
            "$seq" "$suppressed" "$demoted" "$dcount"
    done < <(printf '%s' "$ranked" | jq -c '.[]')
}

# _explain_write_artifact <winner_pane_id> <ranked candidates json>
# Writes $HERDR_PLUGIN_STATE_DIR/explain.json, a sibling diagnostic
# artifact -- never read back by schedule() itself, so it cannot ever
# influence a real scheduling decision. This is purely so `explain`'s
# report is also available machine-readably (design doc: "writes a
# `last_decision` object to state (or a sibling explain.json)"). Written
# only when the explain action itself runs (not on every dispatch yield):
# computing/printing this is already explain's whole job, so there is no
# extra cost here, whereas writing it from schedule()'s hot path would add
# a jq/file-write cost to every real dispatch for a diagnostic most yields
# will never have looked at -- kept out of scope for this minimal first
# cut, same "ship the small thing first" discipline as the rest of this
# cycle. Same permissions discipline as state.json: 700 dir, 600 file,
# atomic tmp-file + mv (lib/state.sh's state_save pattern). Best-effort:
# a write failure here must never fail the (read-only) explain action
# itself, so all failure paths are swallowed.
_explain_write_artifact() {
    local winner="$1" candidates_json="$2" out_file tmp
    out_file="$STATE_DIR/explain.json"
    mkdir -p "$STATE_DIR" 2>/dev/null || true
    chmod 700 "$STATE_DIR" 2>/dev/null || true
    tmp="$out_file.tmp.$$"
    if ! jq -n --arg w "$winner" --argjson c "$candidates_json" '
        {winner_pane_id: (if $w == "" then null else $w end),
         candidates: ($c | map({pane_id, class, affinity_rank, aged,
                                 state_change_seq: .seq,
                                 suppressed: .is_suppressed, demoted: .is_demoted}))}
    ' >"$tmp" 2>/dev/null; then
        rm -f "$tmp" 2>/dev/null || true
        return 0
    fi
    chmod 600 "$tmp" 2>/dev/null || true
    mv "$tmp" "$out_file" 2>/dev/null || true
}

# explain_decision <departure_pane_id>
# Read-only introspection for the `explain` action (design doc "Revised
# recommended order" item 1). Reports why the scheduler would pick what it
# picks for this departure pane by calling the exact same
# _classify_candidate/_affinity_rank/_workspace_locality_rank/
# _lineage_trusted/_resolve_confirm helpers schedule() itself calls -- this
# function is not a second copy of the cascade that could drift from the
# real one; it IS the real cascade, run against a throwaway copy of state.
#
# HARD REQUIREMENT, not a yield point: this function must NEVER call
# `agent focus`, and never does -- it never acquires the state lock and
# never calls state_save, so even though _classify_candidate can compute a
# hypothetical false-claim demotion or a lineage-forget exactly like
# schedule() would, none of it is ever persisted to state.json here, let
# alone acted on by moving focus. explain is read-only by construction,
# not merely by convention.
explain_decision() {
    local departure_pane_id="$1"
    local agents_json state now_ms

    config_load

    if ! agents_json=$(agent_list_json); then
        echo "bashauma: explain: could not reach herdr (agent list failed) -- nothing to report (prd.md §10: never guess)." >&2
        return 0
    fi

    now_ms=$(_now_ms)
    state=$(state_load)

    # Same false-claim-demotion check schedule() performs (prd.md §6.4),
    # applied only to this function's local copy of state -- see this
    # function's header comment for why that's still read-only overall.
    # log_enabled="false": this copy of state is NEVER state_save()'d, so
    # any A-0 threshold-crossing this hypothetical demotion would compute
    # must not be logged as if it really happened (Hockney review, MAJOR
    # finding, tests/cases/a0_suppression_logging.sh Scenario D).
    local last_winner last_winner_was_p0 last_winner_status last_winner_seq already_fed
    last_winner=$(printf '%s' "$state" | jq -r '.last_winner_pane_id // empty')
    last_winner_was_p0=$(printf '%s' "$state" | jq -r '.last_winner_was_p0 // false')
    if [ -n "$last_winner" ] && [ "$last_winner_was_p0" = "true" ]; then
        last_winner_status=$(printf '%s' "$agents_json" | jq -r --arg p "$last_winner" \
            '[.[] | select(.pane_id == $p)][0].agent_status // empty')
        already_fed=$(printf '%s' "$state" | jq -r --arg p "$last_winner" '(.epoch_fed_pane_ids // []) | index($p) != null')
        if [ "$last_winner_status" = "blocked" ] && [ "$already_fed" != "true" ]; then
            last_winner_seq=$(printf '%s' "$agents_json" | jq -r --arg p "$last_winner" \
                '[.[] | select(.pane_id == $p)][0].state_change_seq // 0')
            state=$(_demote_pane_to_p1 "$state" "$last_winner" "$now_ms" "$last_winner_seq" "false")
        fi
    fi

    local dep_tab dep_ws dep_cwd
    dep_tab=$(printf '%s' "$agents_json" | jq -r --arg p "$departure_pane_id" '[.[] | select(.pane_id == $p)][0].tab_id // empty')
    dep_ws=$(printf '%s' "$agents_json" | jq -r --arg p "$departure_pane_id" '[.[] | select(.pane_id == $p)][0].workspace_id // empty')
    dep_cwd=$(printf '%s' "$agents_json" | jq -r --arg p "$departure_pane_id" '[.[] | select(.pane_id == $p)][0].cwd // empty')

    local aging_threshold_ms
    aging_threshold_ms=$((CONFIG_AGING_SECONDS * 1000))

    # No prefetch/cache here (nothing to protect from lock-scope, since
    # explain never takes the lock) -- _resolve_confirm always falls back
    # to a direct confirm_p0 read per blocked candidate, same cost shape
    # as schedule()'s own in-lock fallback path.
    _CONFIRM_CACHE_JSON="{}"

    # log_enabled="false" passed to _classify_candidate below for the same
    # reason as the false-claim check above: nothing this loop computes is
    # ever persisted, so no A-0 log should fire from it.
    local candidates="[]" agent_obj classify_result cand
    while IFS= read -r agent_obj; do
        [ -n "$agent_obj" ] || continue
        classify_result=$(_classify_candidate "$state" "$agent_obj" "$dep_tab" "$dep_ws" "$dep_cwd" "$now_ms" "$aging_threshold_ms" "false")
        state=$(printf '%s' "$classify_result" | jq -c '.state')
        cand=$(printf '%s' "$classify_result" | jq -c '.candidate')
        if [ "$cand" != "null" ]; then
            candidates=$(printf '%s' "$candidates" | jq -c --argjson c "$cand" '. + [$c]')
        fi
    done < <(printf '%s' "$agents_json" | jq -c '.[]')

    local ranked winner_pane_id
    ranked=$(printf '%s' "$candidates" | jq -c '
        map(. + {class_rank: (if .class == "P0" then 0 else 1 end), aged_rank: (if .aged then 0 else 1 end)}) |
        sort_by([.aged_rank, .class_rank, .affinity_rank, .workspace_locality_rank, .seq, .pane_id])
    ')
    winner_pane_id=$(printf '%s' "$ranked" | jq -r '.[0].pane_id // empty')

    _explain_write_artifact "$winner_pane_id" "$ranked"
    _print_explain_report "$departure_pane_id" "$dep_tab" "$dep_ws" "$dep_cwd" "$ranked" "$winner_pane_id"
}
