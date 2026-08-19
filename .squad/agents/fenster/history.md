# Fenster History

## Project context

- Project: herdr extension
- Primary implementation language: shell script
- Preference: lightweight automation without heavyweight frameworks
- Quality bar: normal test, lint, and review expectations
- User: Shun Kinoshita

## Initial orientation

- Keep scripts simple, readable, and portable.
- Avoid unnecessary dependencies or wrappers.
- Make it easy to run, validate, and publish from a clean repo.

## 2026-08-18T22:37:23+09:00: bashauma v1 implementation (prd.md rewrite)

Implemented v1 per Keaton's verified plan (`.squad/decisions/inbox/keaton-v1-implementation-plan.md`):

- Added `lib/state.sh` (mkdir-lock state read/write, ported from v0.1),
  `lib/config.sh` (JSON config with defaults + `BASHAUMA_*` env overrides),
  `lib/scheduler.sh` (core pick-next algorithm: priority classes, P0
  bottom-anchored confirmation, affinity, aging, FIFO, false-claim
  demotion/suppression, epoch/winner-once gating).
- Rewrote `on_status_changed.sh` as the dispatch-yield entrypoint only
  (debounce + re-verify, then schedule on a real `working` transition;
  every other transition just records status, never moves focus).
- Added `next.sh` as the explicit-yield entrypoint (`next` action), reading
  the departure pane from `HERDR_PLUGIN_CONTEXT_JSON.focused_pane_id` with
  an `agent list`-based fallback for callers that don't set it.
- Deleted outright: v0.1's finish-focus redirect, `pane_is_active()` /
  viewport-diffing, and the round-based `round_done_pane_ids` model.
- Updated `herdr-plugin.toml` to v1.0.0 / min_herdr_version 0.8.0, added the
  `next` `[[actions]]` entry (no `[[keybindings]]` table -- confirmed not to
  exist; documented as a user-side README concern instead).
- All scripts pass `bash -n` and `shellcheck -x` (SC2034 false positives on
  lib files in isolation are cross-file usage, confirmed clean via `-x`).
- Fixed a real bug found while testing: several `[ cond ] && action`
  standalone statements silently tripped `set -e` (errexit) whenever the
  condition was false, since that pattern is only errexit-exempt inside an
  `if`/`while` guard -- converted every such site to explicit `if; then; fi`.
- `tests/run_tests.sh`: 10/10 case files, 50/50 assertions passing,
  stable across repeated runs (verified timing-sensitive debounce/aging/
  flicker cases specifically for flakiness).
- Extended `lib/config.sh` to accept `BASHAUMA_MODE`, `BASHAUMA_AFFINITY`,
  `BASHAUMA_PARKED_PANES` (comma-separated), `BASHAUMA_BLOCKED_CONFIRM`,
  `BASHAUMA_BLOCKED_CONFIRM_LINES`/`_PATTERN` env overrides in addition to
  `BASHAUMA_AGING_SECONDS`, since Hockney's `tests/cases/6_8_config.sh`
  (flagged by him as an assumption) exercises these -- config.json remains
  the primary/documented mechanism, env vars are the override layer.
- Also discovered `mode = "off"` must disable only the *automatic*
  dispatch-triggered scheduling, not the explicit `next` action (prd.md
  §6.8 says "off ... keeps the next action" -- the action must still
  actually schedule, not just stay registered/inert). Moved the mode gate
  into `on_status_changed.sh` rather than inside `schedule()` itself.

📌 Team update (2026-08-18T22:37:23+09:00): v1 scheduler/state/config implementation merged into decisions.md; the lock-scope blocker found in Hockney's review was fixed by Keaton in a follow-up cycle (Fenster locked out of that revision per reviewer-protocol, as original author) — decided by Fenster/Hockney/Keaton.
