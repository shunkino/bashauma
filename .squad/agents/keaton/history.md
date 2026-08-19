# Keaton History

## Project context

- Project: herdr extension
- Primary language: shell-first scripting
- Operating model: lightweight, portable automation
- Quality bar: normal testing, review, linting, and publish-readiness checks
- User: Shun Kinoshita

## Initial orientation

- Keep the project small and maintainable.
- Use shell scripts as the primary implementation language when practical.
- Favor simple workflows and clear ownership.
- Make repository publication straightforward without introducing unnecessary platform complexity.

## Session: v1 implementation plan (2026-08-18T22:37:23+09:00)

- Task: design (no implementation) a complete v1 plan for prd.md's
  non-preemptive scheduler rewrite, for Fenster to execute.
- Verified the real herdr 0.8.0-preview CLI/manifest surface live rather than
  trusting prd.md's assumptions:
  - `agent list`/`agent get` fields confirmed exact match to PRD (agent_status,
    state_change_seq, tab_id, workspace_id, cwd, focused, pane_id).
  - Confirmed `herdr-plugin.toml` has NO `[[keybindings]]` table — only
    `[[actions]]` (fields: id, title, description, command, platforms,
    contexts), found via `strings` on the binary (RawPluginManifestAction) and
    a live `herdr plugin action list`/`invoke` test. Keybindings are
    configured by the *user* in their own config.toml via `[[keys.command]]`
    with `type = "plugin_action"`, `action_id`, optional `plugin_id`.
  - Confirmed action/event scripts receive `HERDR_PLUGIN_CONTEXT_JSON` /
    `HERDR_PLUGIN_EVENT_JSON` with the departure pane's context, which the
    algorithm uses for affinity.
  - Read the existing `tests/` scaffold (Hockney's work already in-repo) and
    locked entrypoint file names to its documented defaults:
    `on_status_changed.sh` (dispatch yield) and `next.sh` (explicit yield).
- Delivered: verified API surface, file layout, manifest TOML diff, state
  schema + mkdir-lock justification, full pick-next pseudocode, config
  loading/defaults incl. `blocked_confirm_pattern` ERE, v0.1 removal list, and
  ordered task breakdown — all in-session response to the requester.
- Wrote `.squad/decisions/inbox/keaton-v1-implementation-plan.md` for Fenster/
  Hockney/Verbal.
- No source files were created or modified (design-only task); manifest was
  temporarily test-edited during CLI verification and fully reverted
  (confirmed via `git status --short` showing no diff to tracked plugin
  files).

## Session: v1 review-rejection fix (2026-08-18T22:37:23+09:00)

- Task: Hockney REJECTED Fenster's v1 implementation and named me (Keaton)
as fix agent, since Fenster is locked out of `lib/state.sh`,
`lib/config.sh`, `lib/scheduler.sh`, `on_status_changed.sh`, `next.sh`,
`herdr-plugin.toml` per reviewer-protocol strict lockout for this
revision cycle. Did not consult Fenster; worked the files directly.
- Fixed BLOCKER 1 (state lock held across `agent list`/`pane read`,
risking the stale-lock reclaim heuristic force-breaking a live holder's
lock): restructured `schedule()` in `lib/scheduler.sh` into an unlocked
herdr-I/O phase (agent list snapshot + pre-fetched P0 confirmations,
using an unlocked read of state.json -- safe since state_save always
writes via tmp+atomic-mv) followed by a lock phase containing only local
jq/state work, with a rare in-lock fallback re-fetch for candidates the
pre-lock snapshot couldn't anticipate.
- Fixed BLOCKER 2 (fractional `aging_seconds` crashing bash `$(( ))` under
`set -e`, silently dropping the yield): added `_config_to_int` to
`lib/config.sh`, applied to `aging_seconds`, `blocked_confirm_lines`, and
the new `p0_suppress_after_demotions` -- truncates valid (possibly
fractional/negative) numbers, falls back to the compiled-in default for
garbage. Also hardened `lib/state.sh`'s `STATE_LOCK_STALE_SECONDS` the
same way.
- Fixed Rai's two advisory findings: grep option-injection in `confirm_p0`
(now `grep -Eqe`) and state dir/lock/file permissions
(`chmod 700`/`chmod 600` in `lib/state.sh`).
- Addressed Hockney's minor/nit items: named+configurable the "3 demotions"
threshold (`p0_suppress_after_demotions`, new config key -- flagged for
Verbal), added a final `pane_id` sort tiebreaker for full determinism,
moved the `mode=off` check in `on_status_changed.sh` before the debounce
sleep, and left a documented, deliberate gap (code comment, no fix) for
the transient `agent get` failure case and deferred the ANSI-escape/date
`%N` fallback items as low-confidence, not-confirmed-defect follow-ups.
- Verification: `bash -n` and `shellcheck -x` clean on all 5 owned scripts
(one pre-existing SC2034 false positive in `lib/config.sh` from
cross-file global usage, silenced with a documented directive).
`tests/run_tests.sh`: 12/12 pass (original 10 + Hockney's 2 new
regressions), stable across repeated runs. Manually verified malformed
regex fail-safe, state file/dir permissions, and the mode=off timing fix
by hand outside the test harness.
- Wrote `.squad/decisions/inbox/keaton-v1-review-fix.md` flagging the new
`p0_suppress_after_demotions` config key for Verbal's README update.
- Did not edit `tests/`, `README.md`, `CHANGELOG.md`, or `prd.md`.

📌 Team update (2026-08-18T22:37:23+09:00): v1 implementation plan (herdr API verification, no [[keybindings]] in manifest) and the 3-phase lock-discipline fix for Hockney's rejected review are both merged into decisions.md — decided by Keaton.
