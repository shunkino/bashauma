#!/bin/bash
# REGRESSION — GitHub issue #2: _config_to_int must warn to stderr on
# outright rejection of a numeric config value (naming the key, the
# offending value, and the default now in use), and must NOT warn for a
# valid fractional value that's merely truncated (that's documented,
# expected behavior, not an error).
#
# Message format asserted verbatim (per issue #2's suggested fix and
# lib/config.sh's own docstring):
#   bashauma: config key '<key>' has invalid value "<raw>" — using default <fallback>
set -u
. "$(dirname "$0")/../lib/harness.sh"

# _set_aging_seconds_via_config <raw JSON value>
# Writes config.json with the given (possibly-garbage) aging_seconds
# value. Using config.json rather than BASHAUMA_AGING_SECONDS so an empty
# string can actually reach _config_to_int -- config_load's env-override
# branch is gated on `[ -n "$BASHAUMA_AGING_SECONDS" ]`, so an empty env
# var would never override anything, but an empty *JSON* value is applied
# unconditionally.
_set_aging_seconds_via_config() { # $1 raw value (JSON-encoded)
    printf '{"aging_seconds": %s}' "$1" >"$HERDR_PLUGIN_CONFIG_DIR/config.json"
}

# Plain indexed (bash 3.2-safe -- no associative arrays) array of raw JSON
# values to write into config.json for aging_seconds. What
# config_load/_config_to_int actually sees is whatever `jq -r
# '.aging_seconds'` prints for each of these (computed the same way here,
# via jq, rather than hand-duplicated) -- so the expected message is
# derived, not guessed, keeping this test honest about what the string
# actually looks like once it round-trips through jq (e.g. `1e3` prints
# as `1E+3`, not `1e3` or `1000`).
raw_values=('"5m"' '1e3' '"+5"' '"  30  "' '""')

setup_test
export HERDR_PLUGIN_CONFIG_DIR="$HERDR_PLUGIN_STATE_DIR"
for raw_json in "${raw_values[@]}"; do
    printed_raw=$(printf '{"v": %s}' "$raw_json" | jq -r '.v')
    expected_msg="bashauma: config key 'aging_seconds' has invalid value \"$printed_raw\" — using default 300"

    _set_aging_seconds_via_config "$raw_json"
    stub_set_agent_list '[{"pane_id":"p1","agent_status":"idle","state_change_seq":1,"tab_id":"t1","workspace_id":"ws1","cwd":"/repo","focused":true}]'

    invoke_next "p1"
    rc=$?
    if [ "$rc" -eq 127 ]; then
        fail_not_implemented "BASHAUMA_NEXT_CMD (config warning for aging_seconds=$raw_json)"
        break
    else
        assert_contains "$HARNESS_LAST_OUTPUT" "$expected_msg" \
            "config.json aging_seconds=$raw_json must warn with the exact documented message"
    fi
done
teardown_test

# --- valid fractional truncation must NOT warn ------------------------------
setup_test
export HERDR_PLUGIN_CONFIG_DIR="$HERDR_PLUGIN_STATE_DIR"
_set_aging_seconds_via_config "2.7"
stub_set_agent_list '[{"pane_id":"p1","agent_status":"idle","state_change_seq":1,"tab_id":"t1","workspace_id":"ws1","cwd":"/repo","focused":true}]'

invoke_next "p1"
rc=$?
if [ "$rc" -eq 127 ]; then
    fail_not_implemented "BASHAUMA_NEXT_CMD (no warning for valid fractional truncation)"
else
    assert_not_contains "$HARNESS_LAST_OUTPUT" "invalid value" \
        "a valid fractional value (2.7 -> 2) is documented, expected truncation and must NOT warn"
fi
teardown_test

harness_report_and_exit
