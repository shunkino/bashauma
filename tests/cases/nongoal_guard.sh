#!/bin/bash
# PRD §5 (Non-Goals) — static guard.
#
# "No notifications. bashauma never emits `herdr notification show`."
# This is a hard non-goal, and unlike the rest of the suite it's cheap and
# reliable to check statically rather than behaviorally: grep the plugin's
# own shell sources (excluding this test suite and vendored/fixture code)
# for any invocation of `notification show`.
#
# The runtime half of "agent focus is never called outside a yield point" is
# covered behaviorally by 6_5_non_dispatch_no_focus.sh (the hard invariant
# from §9) -- this file adds a cheap static sanity check on top: `agent
# focus` should not appear literally anywhere outside the scheduler/next
# entrypoints (e.g. not in winner_screen.sh, not in the manifest).
set -u
. "$(dirname "$0")/../lib/harness.sh"

# Only the plugin's own shipped shell scripts -- never tests/ (which
# legitimately references these strings in comments/fixtures) and never
# prd.md or README.md (prose, not code).
# Only the plugin's own shipped shell scripts -- never tests/ (which
# legitimately references these strings in comments/fixtures) and never
# prd.md or README.md (prose, not code). Avoids `mapfile` (bash 4+) for
# compatibility with the stock bash 3.2 shipped on macOS.
PLUGIN_SCRIPTS=$(find "$REPO_ROOT" -maxdepth 1 -name '*.sh' -type f | sort)

echo "checking:"
printf '%s\n' "$PLUGIN_SCRIPTS" | sed 's/^/  /'

# --- notification show is never invoked ------------------------------------
found_notification=""
while IFS= read -r f; do
    [ -n "$f" ] || continue
    if grep -n "notification show" "$f" >/dev/null 2>&1; then
        found_notification="$found_notification $f"
    fi
done <<EOF
$PLUGIN_SCRIPTS
EOF
assert_eq "$found_notification" "" "no shipped script may invoke 'herdr notification show' (§5 non-goal)"

# --- agent focus is confined to files that implement a yield point --------
# winner_screen.sh renders the celebration popup only; it must never itself
# call `agent focus`.
if [ -f "$REPO_ROOT/winner_screen.sh" ]; then
    winner_focus_calls=$(grep -c "agent focus" "$REPO_ROOT/winner_screen.sh" || true)
    assert_eq "$winner_focus_calls" "0" "winner_screen.sh (the celebration popup) must never call agent focus"
fi

harness_report_and_exit
