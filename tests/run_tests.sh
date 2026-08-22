#!/bin/sh
# bashauma test runner.
#
# Dependency-free (no bats, no external test framework) — just POSIX sh,
# bash (already a plugin requirement), and jq (already a plugin requirement).
#
# Usage:
#   tests/run_tests.sh              # run every case in tests/cases/
#   tests/run_tests.sh 6_1 6_5      # run only cases whose filename contains
#                                   # one of these substrings
#
# ---------------------------------------------------------------------------
# ENTRYPOINT INDIRECTION
#
# Fenster's implementation is expected to land as on_status_changed.sh
# (dispatch yield / status-changed hook) and a new next.sh (explicit `next`
# yield action). If those file names change before landing, override the
# indirection points instead of editing every test case:
#
#   BASHAUMA_SCHEDULER_CMD=/path/to/real/hook tests/run_tests.sh
#   BASHAUMA_NEXT_CMD=/path/to/real/next tests/run_tests.sh
#
# See tests/lib/harness.sh (top of file) for the full contract.
# ---------------------------------------------------------------------------

set -eu

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
CASES_DIR="$SCRIPT_DIR/cases"

if [ -t 1 ]; then
    C_RED='\033[31m'
    C_GREEN='\033[32m'
    C_BOLD='\033[1m'
    C_RESET='\033[0m'
else
    C_RED=''
    C_GREEN=''
    C_BOLD=''
    C_RESET=''
fi

filters="$*"

total=0
passed=0
failed=0
failed_names=""

for case_file in "$CASES_DIR"/*.sh; do
    [ -e "$case_file" ] || continue
    name=$(basename "$case_file" .sh)

    if [ -n "$filters" ]; then
        matched=0
        for f in $filters; do
            case "$name" in
            *"$f"*) matched=1 ;;
            esac
        done
        [ "$matched" -eq 1 ] || continue
    fi

    total=$((total + 1))
    printf '%s▶ %s%s\n' "$C_BOLD" "$name" "$C_RESET"

    if output=$(sh -c '"$1"' _ "$case_file" 2>&1); then
        rc=0
    else
        rc=$?
    fi

    if [ -n "$output" ]; then
        printf '%s\n' "$output" | sed 's/^/  /'
    fi

    if [ "$rc" -eq 0 ]; then
        passed=$((passed + 1))
        printf '%s✔ PASS%s: %s\n\n' "$C_GREEN" "$C_RESET" "$name"
    else
        failed=$((failed + 1))
        failed_names="$failed_names $name"
        printf '%s✘ FAIL%s: %s (exit %d)\n\n' "$C_RED" "$C_RESET" "$name" "$rc"
    fi
done

printf '%s=== bashauma test summary ===%s\n' "$C_BOLD" "$C_RESET"
printf 'total: %d  %spassed: %d%s  %sfailed: %d%s\n' \
    "$total" "$C_GREEN" "$passed" "$C_RESET" "$C_RED" "$failed" "$C_RESET"

if [ "$total" -eq 0 ]; then
    printf '%sno test cases matched%s\n' "$C_RED" "$C_RESET"
    exit 1
fi

if [ "$failed" -gt 0 ]; then
    printf '%sfailed cases:%s%s\n' "$C_RED" "$C_RESET" "$failed_names"
    exit 1
fi

exit 0
