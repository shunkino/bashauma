#!/bin/bash
# bashauma test harness library.
#
# Sourced by every file in tests/cases/. Provides:
#   - assert_eq / assert_contains / assert_not_contains / assert_exit_code
#   - per-test setup (fresh HERDR_PLUGIN_STATE_DIR + herdr stub sandbox)
#   - helpers for scripting the fake `herdr` CLI (tests/fixtures/bin/herdr)
#   - helpers for asserting on what the scheduler did (focus calls, winner
#     screen fires, ...)
#
# ---------------------------------------------------------------------------
# ENTRYPOINT INDIRECTION (confirmed by Keaton, 2026-08-18 — see
# .squad/decisions/inbox/keaton-v1-implementation-plan.md)
#
# Every test drives the scheduler through two documented, overridable
# indirection points (prd.md §6.1: dispatch yield vs explicit `next` yield
# are two distinct entrypoints):
#
#   BASHAUMA_SCHEDULER_CMD   - invoked for a *dispatch yield*: a
#                              `pane.agent_status_changed` event. Defaults to
#                              "$REPO_ROOT/on_status_changed.sh" (locked file
#                              name, confirmed by Keaton). Called via
#                              invoke_status_changed().
#
#   BASHAUMA_NEXT_CMD        - invoked for an *explicit yield*: the `next`
#                              action. Defaults to "$REPO_ROOT/next.sh"
#                              (locked file name, confirmed by Keaton).
#                              Called via invoke_next().
#
#   BASHAUMA_EXPLAIN_CMD     - invoked for the v1.1 `explain` action (design:
#                              .squad/design/v1.1-scheduling.md, "Revised
#                              recommended order" item 1). Defaults to
#                              "$REPO_ROOT/explain.sh" -- NOT YET CONFIRMED
#                              by Keaton/Fenster at the time this harness
#                              support was written (proactive, ahead of the
#                              implementation, same as the rest of this
#                              file). Called via invoke_explain().
#
#              *** CONFIRMED explain OUTPUT CONTRACT (2026-08-19, once
#                  Fenster's implementation landed) ***
#              explain_decision() (lib/scheduler.sh) computes the ranked
#              candidate list live, on every invocation. It also writes a
#              best-effort $HERDR_PLUGIN_STATE_DIR/explain.json sibling
#              artifact (700/600 perms, atomic tmp+mv) for machine-readable
#              introspection -- added by Fenster after this comment was
#              first written; schedule() never reads it back, so it can't
#              feed into a real decision. Not currently asserted on by this
#              harness (only the stdout contract below is parsed) -- a
#              known nit, not a gap that blocks anything, since the stdout
#              marker already fully proves winner correctness.
#              Its report is plain human-readable stdout
#              (_print_explain_report()), one block per candidate, with the
#              winning candidate's line ending in the literal marker
#              "<-- WINNER" -- e.g.:
#                  1. w1:p2 (raw_status=blocked)  <-- WINNER
#              explain_winner_pane_id() below parses that line out of
#              $HARNESS_LAST_OUTPUT (set by invoke_explain()) rather than
#              reading any file. If this format ever changes, only
#              explain_winner_pane_id() needs updating -- the *intent* of
#              each assertion (never focuses, winner matches the real
#              cascade, never fires on a failed agent list, etc.) should
#              not need rewriting.
#
# Both entrypoints receive HERDR_PLUGIN_CONTEXT_JSON (departure-pane context
# for affinity: focused_pane_id, workspace_id, tab_id — confirmed live
# against herdr 0.8.0-preview); the event hook additionally receives
# HERDR_PLUGIN_EVENT_JSON (pane_id, agent_status).
#
# If these ever need to change again, either (a) rename the files to match
# these defaults, or (b) export BASHAUMA_SCHEDULER_CMD / BASHAUMA_NEXT_CMD /
# BASHAUMA_EXPLAIN_CMD to point at the real files. Nothing else in this
# harness needs to change.
# ---------------------------------------------------------------------------
set -u

HARNESS_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export REPO_ROOT
REPO_ROOT="$(cd "$HARNESS_LIB_DIR/../.." && pwd)"

export BASHAUMA_SCHEDULER_CMD="${BASHAUMA_SCHEDULER_CMD:-$REPO_ROOT/on_status_changed.sh}"
export BASHAUMA_NEXT_CMD="${BASHAUMA_NEXT_CMD:-$REPO_ROOT/next.sh}"
export BASHAUMA_EXPLAIN_CMD="${BASHAUMA_EXPLAIN_CMD:-$REPO_ROOT/explain.sh}"

# Colors (disabled when not attached to a tty, e.g. CI logs).
if [ -t 1 ]; then
    C_RED=$'\033[31m'
    C_GREEN=$'\033[32m'
    C_YELLOW=$'\033[33m'
    C_RESET=$'\033[0m'
else
    C_RED=""
    C_GREEN=""
    C_YELLOW=""
    C_RESET=""
fi

# Per-case-file failure counter. Assertions increment this instead of
# aborting immediately, so a single case file reports every failing
# assertion in one run instead of stopping at the first.
HARNESS_FAILURES=0
HARNESS_ASSERTIONS=0

# ---------------------------------------------------------------------------
# Setup / teardown
# ---------------------------------------------------------------------------

# Call at the top of every test case (or every sub-scenario within a case
# file that needs isolated state). Creates a fresh temp dir used both as
# HERDR_PLUGIN_STATE_DIR (real plugin state) and HERDR_STUB_DIR (fake herdr
# CLI fixtures + logs), and puts the stub first on PATH.
setup_test() {
    HARNESS_TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/bashauma-test.XXXXXX")"
    export HERDR_PLUGIN_STATE_DIR="$HARNESS_TMP_DIR/state"
    export HERDR_STUB_DIR="$HARNESS_TMP_DIR/stub"
    mkdir -p "$HERDR_PLUGIN_STATE_DIR" "$HERDR_STUB_DIR/agent_get" "$HERDR_STUB_DIR/pane_read"
    export HERDR_STUB_LOG="$HERDR_STUB_DIR/herdr_invocations.log"
    : >"$HERDR_STUB_LOG"
    export HERDR_BIN_PATH="$REPO_ROOT/tests/fixtures/bin/herdr"
    export PATH="$REPO_ROOT/tests/fixtures/bin:$PATH"
    # Keep debounce/activity waits out of test wall-clock time unless a case
    # specifically wants to exercise timing (e.g. flicker, §6.6).
    export BASHAUMA_DEBOUNCE_SECONDS="${BASHAUMA_DEBOUNCE_SECONDS_OVERRIDE:-0.05}"
    export BASHAUMA_ACTIVITY_CHECK_SECONDS="${BASHAUMA_ACTIVITY_CHECK_SECONDS_OVERRIDE:-0.05}"
}

teardown_test() {
    [ -n "${HARNESS_TMP_DIR:-}" ] && rm -rf "$HARNESS_TMP_DIR"
}

# ---------------------------------------------------------------------------
# Assertions
# ---------------------------------------------------------------------------

_harness_record_failure() { # $1 message
    HARNESS_FAILURES=$((HARNESS_FAILURES + 1))
    printf '  %s✗ %s%s\n' "$C_RED" "$1" "$C_RESET" >&2
}

_harness_record_pass() { # $1 message
    :
}

assert_eq() { # $1 actual, $2 expected, $3 message
    HARNESS_ASSERTIONS=$((HARNESS_ASSERTIONS + 1))
    local actual="$1" expected="$2" message="${3:-assert_eq}"
    if [ "$actual" = "$expected" ]; then
        _harness_record_pass "$message"
    else
        _harness_record_failure "$message: expected [$expected], got [$actual]"
    fi
}

assert_contains() { # $1 haystack, $2 needle, $3 message
    HARNESS_ASSERTIONS=$((HARNESS_ASSERTIONS + 1))
    local haystack="$1" needle="$2" message="${3:-assert_contains}"
    case "$haystack" in
    *"$needle"*) _harness_record_pass "$message" ;;
    *) _harness_record_failure "$message: expected to find [$needle] in [$haystack]" ;;
    esac
}

assert_not_contains() { # $1 haystack, $2 needle, $3 message
    HARNESS_ASSERTIONS=$((HARNESS_ASSERTIONS + 1))
    local haystack="$1" needle="$2" message="${3:-assert_not_contains}"
    case "$haystack" in
    *"$needle"*) _harness_record_failure "$message: did not expect to find [$needle] in [$haystack]" ;;
    *) _harness_record_pass "$message" ;;
    esac
}

# fail_not_implemented <message>
# Use when an invoke_* helper returns 127 (the configured entrypoint doesn't
# exist yet). Records a real, informative failure rather than silently
# skipping — per-task expectation, tests SHOULD fail loudly until Fenster's
# implementation lands.
fail_not_implemented() { # $1 message
    HARNESS_ASSERTIONS=$((HARNESS_ASSERTIONS + 1))
    _harness_record_failure "NOT IMPLEMENTED YET: $1"
}

assert_exit_code() { # $1 expected, $2 actual, $3 message
    HARNESS_ASSERTIONS=$((HARNESS_ASSERTIONS + 1))
    local expected="$1" actual="$2" message="${3:-assert_exit_code}"
    if [ "$actual" = "$expected" ]; then
        _harness_record_pass "$message"
    else
        _harness_record_failure "$message: expected exit code $expected, got $actual"
    fi
}

# Report the case file's result. Call once, at the end of the file.
# Exits non-zero if any assertion failed (this is what run_tests.sh checks).
harness_report_and_exit() {
    if [ "$HARNESS_FAILURES" -gt 0 ]; then
        printf '%s%d assertion(s) failed out of %d%s\n' "$C_RED" "$HARNESS_FAILURES" "$HARNESS_ASSERTIONS" "$C_RESET" >&2
        exit 1
    fi
    printf '%sall %d assertion(s) passed%s\n' "$C_GREEN" "$HARNESS_ASSERTIONS" "$C_RESET"
    exit 0
}

# ---------------------------------------------------------------------------
# herdr stub scripting helpers
# ---------------------------------------------------------------------------

# stub_set_agent_list <json>
# $1 must be a JSON array of agent objects, e.g.:
#   '[{"pane_id":"w1:p1","agent_status":"idle","state_change_seq":1,
#      "tab_id":"t1","workspace_id":"ws1","cwd":"/repo","focused":true}]'
stub_set_agent_list() {
    jq -c --argjson agents "$1" '{result:{agents:$agents}}' <<<'{}' >"$HERDR_STUB_DIR/agent_list.json"
}

# stub_set_agent_get <pane_id> <agent_status_json_fragment>
# Overrides the synthesized `agent get` response for one pane, e.g. to
# script a debounce re-verification returning a *different* status than
# agent_list.json (flicker tests, §6.6).
stub_set_agent_get() { # $1 pane_id, $2 agent JSON object
    printf '%s' "$2" | jq -c '{result:{agent: .}}' >"$HERDR_STUB_DIR/agent_get/$1.json"
}

# stub_set_pane_read <pane_id> <<'EOF' ... EOF
# Reads scrollback content from stdin and stores it as the `pane read
# <pane_id> --source visible` fixture.
stub_set_pane_read() { # $1 pane_id
    cat >"$HERDR_STUB_DIR/pane_read/$1.txt"
}

stub_fail_agent_list() {
    : >"$HERDR_STUB_DIR/agent_list.fail"
}

stub_fail_focus() {
    : >"$HERDR_STUB_DIR/focus.fail"
}

stub_set_winner_ui_busy() {
    : >"$HERDR_STUB_DIR/winner.ui_busy"
}

# ---------------------------------------------------------------------------
# Invocation helpers (the "documented indirection" from the header comment)
# ---------------------------------------------------------------------------

# _harness_context_json <pane_id>
# Builds the HERDR_PLUGIN_CONTEXT_JSON payload for the departure pane,
# looking it up in the currently-scripted agent_list.json fixture when
# possible. Confirmed by Keaton (2026-08-18, verified live against herdr
# 0.8.0-preview) to include at least focused_pane_id, workspace_id, tab_id;
# both the event hook and the `next` action receive this alongside their
# own event/action-specific payload.
_harness_context_json() { # $1 pane_id (the departure pane)
    local pane_id="$1"
    if [ -s "$HERDR_STUB_DIR/agent_list.json" ]; then
        jq -c --arg p "$pane_id" \
            '(.result.agents[] | select(.pane_id == $p)) as $a |
             {focused_pane_id: $p, workspace_id: ($a.workspace_id // null), tab_id: ($a.tab_id // null)}' \
            "$HERDR_STUB_DIR/agent_list.json" 2>/dev/null || printf '{"focused_pane_id":"%s"}' "$pane_id"
    else
        printf '{"focused_pane_id":"%s"}' "$pane_id"
    fi
}

# _harness_run_captured <cmd...>
# Runs <cmd...> with stdout and stderr captured to SEPARATE temp files
# under $HARNESS_TMP_DIR (so the command runs exactly once -- no
# re-invoking side-effecting scripts to get a second stream), then sets:
#   HARNESS_LAST_STDOUT  - stdout only
#   HARNESS_LAST_STDERR  - stderr only
#   HARNESS_LAST_OUTPUT  - stdout and stderr concatenated (stdout first),
#                          kept for backward compatibility with existing
#                          assert_contains/assert_not_contains calls that
#                          don't care which stream a message landed on
#                          (e.g. regression_config_warning.sh's stderr
#                          warning-text checks, which only ever assert
#                          substring presence, never stream identity or
#                          interleaving order).
# Returns the command's exit code.
#
# Added 2026-08-20 (Hockney review follow-up): a0_suppression_logging.sh's
# Scenario D needs to assert on the ABSENCE of a specific stderr log line
# from a read-only `explain` call, but explain's real, legitimate stdout
# report also discusses suppression by name (the `p0_suppress_after_demotions`
# config key, a per-candidate `suppressed=` field) -- a bare keyword check
# against the fused stream can never tell "explain talked about
# suppression" (fine, expected, its whole job) apart from "A-0's real
# threshold-crossing log fired" (the actual defect). Separating the
# streams lets Scenario D (and C, which has the same latent fragility)
# assert against stderr specifically.
_harness_run_captured() { # $@ = command to run (already has env prefix vars set by caller)
    local rc=0
    local out_file="$HARNESS_TMP_DIR/last_stdout.txt" err_file="$HARNESS_TMP_DIR/last_stderr.txt"
    "$@" >"$out_file" 2>"$err_file" || rc=$?
    HARNESS_LAST_STDOUT=$(cat "$out_file")
    HARNESS_LAST_STDERR=$(cat "$err_file")
    HARNESS_LAST_OUTPUT="$HARNESS_LAST_STDOUT
$HARNESS_LAST_STDERR"
    return $rc
}

# invoke_status_changed <pane_id> <agent_status>
# Simulates a `pane.agent_status_changed` event firing for <pane_id>
# transitioning to <agent_status>, by exporting HERDR_PLUGIN_EVENT_JSON (and
# HERDR_PLUGIN_CONTEXT_JSON, for affinity) and running
# $BASHAUMA_SCHEDULER_CMD, exactly as herdr would invoke the event hook.
# Returns the hook's exit code; stdout/stderr are captured separately in
# HARNESS_LAST_STDOUT / HARNESS_LAST_STDERR (and fused, for backward
# compatibility, in HARNESS_LAST_OUTPUT) -- see _harness_run_captured.
invoke_status_changed() { # $1 pane_id, $2 agent_status
    local pane_id="$1" status="$2" rc=0
    if [ ! -x "$BASHAUMA_SCHEDULER_CMD" ]; then
        echo "SKIP-CANDIDATE: BASHAUMA_SCHEDULER_CMD ($BASHAUMA_SCHEDULER_CMD) is not yet an executable file" >&2
        return 127
    fi
    HERDR_PLUGIN_EVENT_JSON="$(jq -c -n --arg p "$pane_id" --arg s "$status" '{pane_id:$p, agent_status:$s}')" \
    HERDR_PLUGIN_CONTEXT_JSON="$(_harness_context_json "$pane_id")" \
    _harness_run_captured "$BASHAUMA_SCHEDULER_CMD" || rc=$?
    return $rc
}

# invoke_next [departure_pane_id]
# Simulates the user invoking the `next` action (explicit yield / §6.1.2).
# If no departure pane id is given, looks up whichever pane the scripted
# agent_list.json marks focused=true.
invoke_next() { # $1 (optional) departure pane_id
    local rc=0 departure_pane="${1:-}"
    if [ ! -x "$BASHAUMA_NEXT_CMD" ]; then
        echo "SKIP-CANDIDATE: BASHAUMA_NEXT_CMD ($BASHAUMA_NEXT_CMD) is not yet an executable file" >&2
        return 127
    fi
    if [ -z "$departure_pane" ] && [ -s "$HERDR_STUB_DIR/agent_list.json" ]; then
        departure_pane=$(jq -r '[.result.agents[] | select(.focused == true)][0].pane_id // empty' "$HERDR_STUB_DIR/agent_list.json")
    fi
    HERDR_PLUGIN_CONTEXT_JSON="$(_harness_context_json "$departure_pane")" \
    _harness_run_captured "$BASHAUMA_NEXT_CMD" || rc=$?
    return $rc
}

# invoke_explain [departure_pane_id]
# Simulates the user invoking the v1.1 `explain` action -- a read-only
# report of the last/would-be scheduling decision. NOT a yield point: must
# never call `agent focus`. Sets HARNESS_LAST_STDOUT/HARNESS_LAST_STDERR
# (and the fused HARNESS_LAST_OUTPUT) to explain's output (see harness
# header comment for the confirmed output contract).
invoke_explain() { # $1 (optional) departure/context pane id
    local rc=0 departure_pane="${1:-}"
    if [ ! -x "$BASHAUMA_EXPLAIN_CMD" ]; then
        echo "SKIP-CANDIDATE: BASHAUMA_EXPLAIN_CMD ($BASHAUMA_EXPLAIN_CMD) is not yet an executable file" >&2
        return 127
    fi
    if [ -z "$departure_pane" ] && [ -s "$HERDR_STUB_DIR/agent_list.json" ]; then
        departure_pane=$(jq -r '[.result.agents[] | select(.focused == true)][0].pane_id // empty' "$HERDR_STUB_DIR/agent_list.json")
    fi
    HERDR_PLUGIN_CONTEXT_JSON="$(_harness_context_json "$departure_pane")" \
    _harness_run_captured "$BASHAUMA_EXPLAIN_CMD" || rc=$?
    return $rc
}

# explain_winner_pane_id
# Parses the pane_id off the "<-- WINNER" line in $HARNESS_LAST_OUTPUT
# (set by the most recent invoke_explain call), or empty if no such line
# is present (e.g. an empty runnable queue). Centralizing the parse here
# means only this one function needs updating if explain's report format
# ever changes.
explain_winner_pane_id() {
    printf '%s\n' "$HARNESS_LAST_OUTPUT" | grep -F -- '<-- WINNER' | head -n 1 | awk '{print $2}'
}


# ---------------------------------------------------------------------------
# Assertions on stub-recorded scheduler behavior
# ---------------------------------------------------------------------------

focus_calls() {
    [ -f "$HERDR_STUB_DIR/focus_calls.log" ] && cat "$HERDR_STUB_DIR/focus_calls.log"
    return 0
}

focus_call_count() {
    focus_calls | grep -c . || true
}

assert_focus_not_called() { # $1 message
    HARNESS_ASSERTIONS=$((HARNESS_ASSERTIONS + 1))
    local count message="${1:-agent focus must not be called}"
    count=$(focus_call_count)
    if [ "$count" = "0" ]; then
        _harness_record_pass "$message"
    else
        _harness_record_failure "$message: agent focus was called $count time(s): $(focus_calls | tr '\n' ',')"
    fi
}

assert_focus_called_with() { # $1 pane_id, $2 message
    HARNESS_ASSERTIONS=$((HARNESS_ASSERTIONS + 1))
    local pane_id="$1" message="${2:-agent focus should target $1}"
    if focus_calls | grep -qxF "$pane_id"; then
        _harness_record_pass "$message"
    else
        _harness_record_failure "$message: focus_calls=[$(focus_calls | tr '\n' ',')]"
    fi
}

assert_focus_call_count() { # $1 expected count, $2 message
    HARNESS_ASSERTIONS=$((HARNESS_ASSERTIONS + 1))
    local expected="$1" message="${2:-agent focus call count}" actual
    actual=$(focus_call_count)
    if [ "$actual" = "$expected" ]; then
        _harness_record_pass "$message"
    else
        _harness_record_failure "$message: expected $expected focus call(s), got $actual: [$(focus_calls | tr '\n' ',')]"
    fi
}

winner_screen_fire_count() {
    [ -f "$HERDR_STUB_DIR/winner_calls.log" ] || { echo 0; return; }
    wc -l <"$HERDR_STUB_DIR/winner_calls.log" | tr -d ' '
}

assert_winner_fired_count() { # $1 expected, $2 message
    HARNESS_ASSERTIONS=$((HARNESS_ASSERTIONS + 1))
    local expected="$1" message="${2:-winner screen fire count}" actual
    actual=$(winner_screen_fire_count)
    if [ "$actual" = "$expected" ]; then
        _harness_record_pass "$message"
    else
        _harness_record_failure "$message: expected $expected winner screen fire(s), got $actual"
    fi
}

herdr_invocation_log() {
    [ -f "$HERDR_STUB_LOG" ] && cat "$HERDR_STUB_LOG"
    return 0
}

# calls_made_while_state_lock_held
# Every herdr invocation (subcommand + args) that occurred while
# $HERDR_PLUGIN_STATE_DIR/state.lock existed (see the fixture stub's
# lock_held_during.log). Used to assert that slow/external calls (agent
# list, pane read) are NOT made while bashauma's own state lock is held —
# see tests/cases/regression_lock_scope.sh.
calls_made_while_state_lock_held() {
    [ -f "$HERDR_STUB_DIR/lock_held_during.log" ] && cat "$HERDR_STUB_DIR/lock_held_during.log"
    return 0
}

assert_no_calls_while_state_lock_held() { # $1 message
    HARNESS_ASSERTIONS=$((HARNESS_ASSERTIONS + 1))
    local message="${1:-no herdr CLI call should be made while the state lock is held}" calls
    calls=$(calls_made_while_state_lock_held)
    if [ -z "$calls" ]; then
        _harness_record_pass "$message"
    else
        _harness_record_failure "$message: calls made while locked: [$(printf '%s' "$calls" | tr '\n' '|')]"
    fi
}
