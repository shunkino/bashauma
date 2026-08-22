#!/bin/bash
# bashauma: state file read/write + mkdir-based lock (prd.md §6.7).
#
# Sourced by on_status_changed.sh and next.sh (and, transitively, by
# lib/scheduler.sh). Ported from v0.1's mkdir-based lock: `flock(1)` is not
# available on stock macOS, and `mkdir` is atomic on both macOS and Linux.
#
# State lives under $HERDR_PLUGIN_STATE_DIR/state.json. All read-modify-write
# sequences must be wrapped in state_acquire_lock/state_release_lock, since
# the pane.agent_status_changed event hook can fire concurrently for several
# panes at once.

: "${HERDR_PLUGIN_STATE_DIR:=${TMPDIR:-/tmp}}"
STATE_DIR="$HERDR_PLUGIN_STATE_DIR"
STATE_FILE="$STATE_DIR/state.json"
STATE_LOCK_DIR="$STATE_DIR/state.lock"
# BASHAUMA_LOCK_STALE_SECONDS must reach the arithmetic in
# state_acquire_lock below; a non-numeric override must never turn into a
# 0-second stale timeout (which would let a live holder's lock be broken
# immediately). Same coercion rule as lib/config.sh's _config_to_int:
# truncate a valid (optionally fractional) number, else fall back to 30.
STATE_LOCK_STALE_SECONDS=$(awk -v v="${BASHAUMA_LOCK_STALE_SECONDS:-30}" 'BEGIN {
    if (v ~ /^-?[0-9]+(\.[0-9]+)?$/ && v > 0) { printf "%d", v } else { printf "%d", 30 }
}')

STATE_DEFAULT_JSON='{
  "epoch_fed_pane_ids": [],
  "pane_status": {},
  "first_runnable_at": {},
  "p0_demoted_pane_ids": [],
  "p0_suppressed_pane_ids": [],
  "demotion_count": {},
  "demotion_seq": {},
  "hold_count": {},
  "last_hold_at": {},
  "hold_seq": {},
  "false_hold_count": {},
  "last_hold_pane_id": null,
  "winner_fired_epoch": false,
  "last_winner_pane_id": null,
  "last_winner_was_p0": false
}'
# demotion_seq: pane_id -> the `state_change_seq` (from `agent list`)
# observed at the moment a demotion/suppression entry was last written for
# that pane_id (GitHub issue #1's restart/ID-reuse gap). state_change_seq
# is monotonically non-decreasing for the same continuously-live agent;
# lib/scheduler.sh's _lineage_trusted() uses a *lower* observed seq than
# what's recorded here as proof the pane_id was recycled by a herdr server
# restart (whose reset per-workspace ID counters state.json, a plain file,
# survives untouched) rather than being the same pane that earned the
# suppression -- see lib/scheduler.sh for the full mechanism.

_state_lock_held=0

# state_release_lock
# Idempotent; safe to call even if the lock was never acquired (also used
# as an EXIT trap by both entrypoints so a killed run can't wedge the lock
# forever for anyone but itself -- see state_acquire_lock's stale escape
# hatch for the case where the killed run's rmdir never happened).
state_release_lock() {
    [ "$_state_lock_held" = "1" ] || return 0
    _state_lock_held=0
    rmdir "$STATE_LOCK_DIR" 2>/dev/null || true
}

# state_acquire_lock
# Blocks (polling every 0.1s) until the lock dir can be created, or until
# STATE_LOCK_STALE_SECONDS elapses, at which point a presumed-dead holder's
# lock is broken and reclaimed.
#
# IMPORTANT for callers: everything done between state_acquire_lock and
# state_release_lock should be fast, local-file-only work (state_load,
# jq transforms, state_save). Slow external calls (herdr CLI round-trips)
# must happen *before* acquiring or *after* releasing this lock -- held
# across them, an arbitrarily slow external call can exceed
# STATE_LOCK_STALE_SECONDS while the holder is still legitimately alive,
# letting a second, concurrent caller reclaim the lock out from under it
# (a double-writer / lost-update hazard on state.json). See
# lib/scheduler.sh's schedule() for how this is structured.
state_acquire_lock() {
    mkdir -p "$STATE_DIR" 2>/dev/null || true
    chmod 700 "$STATE_DIR" 2>/dev/null || true
    local waited=0 max_waits
    max_waits=$(awk "BEGIN{printf \"%d\", $STATE_LOCK_STALE_SECONDS * 10}")
    while ! mkdir "$STATE_LOCK_DIR" 2>/dev/null; do
        waited=$((waited + 1))
        if [ "$waited" -ge "$max_waits" ]; then
            rmdir "$STATE_LOCK_DIR" 2>/dev/null || true
            mkdir "$STATE_LOCK_DIR" 2>/dev/null || return 1
            break
        fi
        sleep 0.1
    done
    _state_lock_held=1
    chmod 700 "$STATE_LOCK_DIR" 2>/dev/null || true
    return 0
}

# state_load
# Prints the current state JSON, or the defaults if the file is
# missing/corrupt. Safe to call without the lock held: state_save() always
# writes via a tmp file + atomic `mv`, so an unlocked reader only ever
# observes a fully-written snapshot (possibly stale, never partial).
# Callers that intend to *mutate* and save state must still hold the lock
# for the whole read-modify-write, to serialize against other writers.
state_load() {
    if [ -s "$STATE_FILE" ] && jq -e . "$STATE_FILE" >/dev/null 2>&1; then
        cat "$STATE_FILE"
    else
        printf '%s' "$STATE_DEFAULT_JSON" | jq -c .
    fi
}

# state_save <json>
# Must be called while holding the lock. Writes atomically (tmp file + mv)
# and keeps state.json owner-only (chmod 600), since
# $HERDR_PLUGIN_STATE_DIR may live in a shared $TMPDIR.
state_save() {
    local tmp="$STATE_FILE.tmp.$$"
    printf '%s\n' "$1" >"$tmp" || return 1
    chmod 600 "$tmp" 2>/dev/null || true
    mv "$tmp" "$STATE_FILE"
}
