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

---

## Session: v1.1 rejection fix cycle 2 — issue #1 pane-ID recycling gap

Hockney rejected Fenster's v1.0.1 fix for GitHub issue #1: Fenster's
presence-based close-pruning (`p0_suppressed_pane_ids`/`demotion_count`
pruned by absence from `agent list`) genuinely fixed unbounded state
growth but did not close the "more serious half" -- stale P0 suppression
surviving a herdr server restart via pane_id recycling, proven by
Hockney's new `tests/cases/regression_id_recycle_suppression.sh`. I was
named fix agent again, Fenster locked out of `lib/scheduler.sh`'s
close-pruning logic for this cycle.

- Investigated the real herdr 0.8.0-preview binary directly (no
  restart performed, to avoid disrupting Shun's live session): confirmed
  no boot/PID/uptime/instance identifier exists anywhere in the
  documented API (`status`, `api snapshot`, `api schema`); found a
  `socket` path whose ctime/mtime circumstantially matches server start
  time but is unverified across an actual restart and unsupported by the
  test stub (no `status` subcommand at all); confirmed `agent_session` is
  absent on at least one live pane (disqualifying it as a universal key);
  confirmed `state_change_seq` is present on every `agent list` entry
  with no new herdr call needed.
- Chose a hybrid approach: `state_change_seq` as a monotonic per-pane
  logical-clock fingerprint. New `demotion_seq` state field records the
  seq observed at each demotion; new `_lineage_trusted()`/
  `_forget_stale_pane()` helpers verify, at classification time, that
  inherited suppression/demotion history is actually about the same
  live pane before trusting it -- untrusted history is wiped and the
  pane is judged fresh. Rejected restart-detection-via-socket (test
  stub can't support it, no documented env var for the socket path, adds
  a hot-path herdr call, unverified across a real restart) and pure
  stronger-identity keying (`agent_session` not universal,
  `terminal_id` durability unverified). Rejected pure timestamp-based
  expiry as not verifying lineage and overlapping/conflating with issue
  #3 (demotion_count decay), which remains separate and unresolved.
- Corrected the close-pruning block's comment (previously claimed,
  incorrectly, to close the restart gap "for free" -- Hockney's
  specific rejection point) and added `demotion_seq` to the maps it
  prunes for growth hygiene.
- Updated `_demote_pane_to_p1()` to take and stamp an `observed_seq`;
  wired `seq`-passing through both demotion call sites (failed P0
  confirmation, and the previous-winner false-claim path).
- Verification: `bash -n`/`shellcheck -x` clean on all 5 owned files.
  `tests/run_tests.sh`: 15/15 pass (12 originals + Fenster's
  `regression_close_reopen_pruning` + `regression_config_warning` +
  Hockney's `regression_id_recycle_suppression`). Hand-traced both new
  regression tests against the fix before writing code to confirm
  neither would conflict.
- Did not restart the live herdr server; documented that evidentiary
  gap explicitly, and reasoned why the fix's correctness does not
  actually depend on unverified restart-behavior details of
  `state_change_seq`.
- Bumped `herdr-plugin.toml` version 1.0.0 -> 1.0.1 to match Verbal's
  already-recorded CHANGELOG entry; no new config key this cycle.
- Wrote `.squad/decisions/inbox/keaton-id-recycle-fix.md` with full
  reasoning, live-herdr findings, and explicit non-resolution of issue
  #3, for Hockney/Rai/Verbal.
- Did not edit `tests/`, `README.md`, `CHANGELOG.md`, or `prd.md`.
