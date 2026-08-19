#!/bin/bash
# bashauma: configuration loading with defaults (prd.md §6.8).
#
# Config is JSON, not TOML: `jq` is already a hard dependency for this
# plugin (state read/write, herdr CLI output parsing), and shipping a
# second ad hoc TOML parser just for a handful of scalar knobs isn't worth
# it. This is a deliberate deviation from prd.md's implicit TOML-everywhere
# assumption -- documented in README.md.
#
# Read from $HERDR_PLUGIN_CONFIG_DIR/config.json. A missing/invalid file
# silently falls back to defaults (all config is optional, "zero required
# configuration" per prd.md §4).
#
# config_load's CONFIG_* globals are consumed by lib/scheduler.sh and the
# two entrypoints after this file is sourced, not within this file itself,
# so shellcheck can't see the cross-file use and flags every one of them
# as unused (SC2034). Disabled below for the whole file; pre-existing
# pattern, not new to this revision.
# shellcheck disable=SC2034

: "${HERDR_PLUGIN_CONFIG_DIR:=${HERDR_PLUGIN_STATE_DIR:-${TMPDIR:-/tmp}}}"
CONFIG_FILE="$HERDR_PLUGIN_CONFIG_DIR/config.json"

CONFIG_DEFAULT_JSON='{
  "mode": "on",
  "aging_seconds": 300,
  "affinity": "tab",
  "parked_panes": [],
  "blocked_confirm_lines": 5,
  "blocked_confirm_pattern": "(esc to cancel|esc cancel).*(enter to (select|confirm|submit)|enter accept)|(enter to (select|confirm|submit)|enter accept).*(esc to cancel|esc cancel)",
  "blocked_confirm": true,
  "p0_suppress_after_demotions": 3
}'

# _config_to_int <raw value> <fallback> [<key name>]
# Coerces a config value that must reach bash's integer-only `$(( ))`
# arithmetic (aging_seconds, blocked_confirm_lines,
# p0_suppress_after_demotions) into a safe integer. prd.md does not
# constrain these to integers, and neither JSON config nor a BASHAUMA_*
# env override is validated upstream, so this is the single choke point
# that guarantees lib/scheduler.sh never hands `$(( ))` anything it can't
# parse (that crash, under `set -e`, silently drops the whole yield --
# see tests/cases/regression_fractional_aging_seconds.sh).
#
# Documented coercion rule: a valid (optionally negative, optionally
# fractional) number is truncated toward zero (e.g. "30.9" -> 30, "-2.9"
# -> -2) -- this is expected, README-documented behavior and must NOT
# warn. Anything else -- non-numeric garbage ("5m"), scientific notation
# (1e3, which awk's numeric regex below deliberately does not accept),
# a leading "+", surrounding whitespace, empty, or null -- is an outright
# rejection: falls back to <fallback> (always one of our own
# already-known-good defaults, so this never itself produces a bad value)
# AND, if <key name> is given, emits a one-line stderr warning naming the
# key, the offending value, and the default now in use.
#
# Confirmed live against the installed herdr 0.8.0-preview binary
# (`herdr plugin log list --plugin bashauma` after `plugin action invoke
# next` with a deliberately bad config value) that a plugin script's
# stderr is NOT swallowed: herdr captures it per-invocation and it is
# inspectable via `herdr plugin log list --plugin <id>` (each log entry
# has its own "stderr" field). It is not proactively pushed into the
# user's face the way a native herdr notification would be, but it is
# real, retrievable, textual diagnostic output rather than dead output
# going nowhere -- so a warning here is not theatre.
_config_to_int() {
    local raw="$1" fallback="$2" key="${3:-}"
    if awk -v v="$raw" 'BEGIN { exit !(v ~ /^-?[0-9]+(\.[0-9]+)?$/) }'; then
        awk -v v="$raw" 'BEGIN { printf "%d", v }'
        return
    fi
    if [ -n "$key" ]; then
        echo "bashauma: config key '$key' has invalid value \"$raw\" — using default $fallback" >&2
    fi
    printf '%s' "$fallback"
}

# config_load
# Populates the CONFIG_* globals from defaults merged with the user's
# config.json (user values win). Every key additionally honors a
# BASHAUMA_<KEY> environment override (BASHAUMA_MODE, BASHAUMA_AGING_SECONDS,
# BASHAUMA_PARKED_PANES as a comma-separated list, BASHAUMA_BLOCKED_CONFIRM,
# ...) -- useful for tests/local tuning without writing a config file, and
# matches the BASHAUMA_DEBOUNCE_SECONDS convention already used for the
# entrypoints' own timing knobs.
config_load() {
    local user_json merged
    if [ -s "$CONFIG_FILE" ] && jq -e . "$CONFIG_FILE" >/dev/null 2>&1; then
        user_json=$(cat "$CONFIG_FILE")
    else
        user_json='{}'
    fi
    merged=$(jq -c -n --argjson defaults "$CONFIG_DEFAULT_JSON" --argjson user "$user_json" '$defaults * $user')

    CONFIG_MODE=$(printf '%s' "$merged" | jq -r '.mode')
    CONFIG_AGING_SECONDS=$(printf '%s' "$merged" | jq -r '.aging_seconds')
    CONFIG_AFFINITY=$(printf '%s' "$merged" | jq -r '.affinity')
    CONFIG_PARKED_PANES_JSON=$(printf '%s' "$merged" | jq -c '.parked_panes')
    CONFIG_BLOCKED_CONFIRM_LINES=$(printf '%s' "$merged" | jq -r '.blocked_confirm_lines')
    CONFIG_BLOCKED_CONFIRM_PATTERN=$(printf '%s' "$merged" | jq -r '.blocked_confirm_pattern')
    CONFIG_BLOCKED_CONFIRM=$(printf '%s' "$merged" | jq -r '.blocked_confirm')
    CONFIG_P0_SUPPRESS_AFTER_DEMOTIONS=$(printf '%s' "$merged" | jq -r '.p0_suppress_after_demotions')

    if [ -n "${BASHAUMA_MODE:-}" ]; then
        CONFIG_MODE="$BASHAUMA_MODE"
    fi
    if [ -n "${BASHAUMA_AGING_SECONDS:-}" ]; then
        CONFIG_AGING_SECONDS="$BASHAUMA_AGING_SECONDS"
    fi
    if [ -n "${BASHAUMA_AFFINITY:-}" ]; then
        CONFIG_AFFINITY="$BASHAUMA_AFFINITY"
    fi
    if [ -n "${BASHAUMA_PARKED_PANES:-}" ]; then
        CONFIG_PARKED_PANES_JSON=$(printf '%s' "$BASHAUMA_PARKED_PANES" | jq -R -c 'split(",") | map(select(length > 0))')
    fi
    if [ -n "${BASHAUMA_BLOCKED_CONFIRM_LINES:-}" ]; then
        CONFIG_BLOCKED_CONFIRM_LINES="$BASHAUMA_BLOCKED_CONFIRM_LINES"
    fi
    if [ -n "${BASHAUMA_BLOCKED_CONFIRM_PATTERN:-}" ]; then
        CONFIG_BLOCKED_CONFIRM_PATTERN="$BASHAUMA_BLOCKED_CONFIRM_PATTERN"
    fi
    if [ -n "${BASHAUMA_BLOCKED_CONFIRM:-}" ]; then
        CONFIG_BLOCKED_CONFIRM="$BASHAUMA_BLOCKED_CONFIRM"
    fi
    if [ -n "${BASHAUMA_P0_SUPPRESS_AFTER_DEMOTIONS:-}" ]; then
        CONFIG_P0_SUPPRESS_AFTER_DEMOTIONS="$BASHAUMA_P0_SUPPRESS_AFTER_DEMOTIONS"
    fi

    # Coerce every numeric knob that reaches bash `$(( ))` arithmetic
    # in lib/scheduler.sh, *after* config.json + env overrides have both
    # had a chance to set it, so garbage/fractional values from either
    # source are caught. Fallbacks are our own compiled-in defaults --
    # never each other -- so a bad override can't cascade into another
    # bad value.
    CONFIG_AGING_SECONDS=$(_config_to_int "$CONFIG_AGING_SECONDS" 300 "aging_seconds")
    CONFIG_BLOCKED_CONFIRM_LINES=$(_config_to_int "$CONFIG_BLOCKED_CONFIRM_LINES" 5 "blocked_confirm_lines")
    CONFIG_P0_SUPPRESS_AFTER_DEMOTIONS=$(_config_to_int "$CONFIG_P0_SUPPRESS_AFTER_DEMOTIONS" 3 "p0_suppress_after_demotions")
}
