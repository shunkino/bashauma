# Changelog

All notable changes to `bashauma` are documented here.

## 1.2.0

An opt-in keyword transition hold for dispatch yields. This is a minor
release because it adds new scheduling configuration and observable
diagnostics, but it is inert by default and does not change the v1.1.0
contract unless you configure it.

### Added

- **Keyword transition hold.** New config keys `hold_keywords` (default
  `[]`), `hold_pattern` (default `""`), `hold_check_lines` (default `15`),
  and `hold_suppress_after` (default `1`) can keep you on the pane you just
  dispatched from when its bottom visible output matches configured hold
  text. The check runs only on a dispatch yield, reads the departure pane's
  bottom `hold_check_lines` non-empty lines, and — when it matches — does
  the null action: records normal dispatch bookkeeping, makes no
  `agent focus` call at all, and logs this exact line to stderr for
  `herdr plugin log list --plugin bashauma`:

  ```text
  bashauma: held pane <pane_id> on dispatch yield (matched <keyword|pattern>: "<value>")
  ```

  `hold_keywords` uses
  case-insensitive fixed-string matching (`grep -Fqi -e`), so regex
  metacharacters are literal; `hold_pattern` is the intentional ERE
  power-user override. With the default empty keyword list and empty pattern,
  the feature is fully inert and spends no extra departure-pane read. (#4)

### Changed

- The explicit `next` action now intentionally bypasses keyword transition
  holds. Pressing `next` immediately after a held dispatch counts as one
  false-hold override for that same pane lineage; at the default
  `hold_suppress_after = 1`, that pane becomes hold-exempt so `next` remains
  the escape hatch when a configured keyword is too broad. (#4)

## 1.1.0

A scheduling refinement (workspace-locality tiebreak), a new diagnostic
action (`explain`), a spec clarification in `prd.md`, and one deliberate
non-fix: no new config keys.

### Added

- **Workspace-locality tiebreak.** A new, fifth lexicographic tier in the
  pick-next cascade (`aged`, `class`, `affinity`, **workspace locality**,
  `state_change_seq`): when candidates are still tied after class, aging,
  and affinity, prefer whichever shares the departing pane's
  `workspace_id`. It is a hard gate, not a weight — it can only break ties
  among candidates that already survived every earlier rule, so it can
  never let locality outrank class or aging.
- **`explain` action.** A new read-only `[[actions]]` entry
  (`herdr plugin action invoke explain`, or bind it yourself — see
  `README.md`) that reports the full ranked candidate list the scheduler
  would use right now, using the identical classification code path as a
  real yield, so the explanation can never drift from the real decision.
  It never calls `agent focus` and never touches the real `state.json` or
  its lock — safe to run at any time, as often as you like. It does write
  a best-effort sibling file, `explain.json`, so the same report is
  available machine-readably; `schedule()` never reads that file back, so
  it cannot feed into a real decision.
- Diagnostic stderr logging (`herdr plugin log list --plugin bashauma`)
  whenever a pane first crosses the `p0_suppress_after_demotions`
  threshold, and whenever a suppressed pane's record is pruned on close.
  This is deliberately *not* paired with a decay mechanism this release:
  demotion decay (tracked as issue #3) has not shipped, on purpose — no
  suppression event has yet been observed in real use, and shipping decay
  logic against a signal nobody has watched fire would be guessing. This
  logging exists to gather that evidence before anything is built against
  it.

### Changed

- `prd.md` §6.4 now states the actual requirement explicitly:
  predictability, not mere reproducibility. The two are different
  properties, and a weighted score can satisfy the latter while failing
  the former; the lexicographic cascade above is a direct consequence of
  requiring the latter.

## 1.0.1

Two v1.0.0 review follow-ups (GitHub issues #1, #2), both bug fixes to
already-shipped behavior — no new config keys, no new commands, nothing
that changes the documented contract in a way that needs a minor bump.

### Fixed

- `p0_suppressed_pane_ids` and `demotion_count` are now pruned from
  `state.json` against the live pane set on every `schedule()` call (the
  same as the other state maps), fixing unbounded `state.json` growth over
  a long, high-churn session. On its own this presence-based pruning
  can't catch a pane whose ID is recycled after a herdr server restart —
  a recycled ID is never observed *absent* from `agent list` before it
  reappears, so a prune keyed on absence can never remove its stale
  entry. That gap is closed separately: `state_change_seq` (already
  returned by `agent list`) is used as a monotonic lineage fingerprint —
  a demotion now records the seq observed at the time, and a pane's
  inherited suppression/demotion history is trusted only if a baseline
  was actually recorded for it and the currently observed seq is at least
  that baseline. Either check failing (no baseline, or a seq regression —
  proof the ID changed hands) wipes that pane's history and treats it as
  fresh. User-visible consequence: a pane can no longer inherit a
  different, long-gone agent's distrust — you won't be silently skipped
  in favor of lower-priority candidates when an agent is genuinely
  blocked and asking you something, even across a herdr restart. Genuine,
  continuously-live false-claimers are unaffected and still get
  suppressed after `p0_suppress_after_demotions` demotions, same as
  before. (Note: `state_change_seq`'s exact behavior across an actual
  herdr server restart wasn't empirically verified — restarting a live
  session to test it was avoided — but the fix doesn't depend on any
  particular reset behavior; the worst case if the assumption is wrong is
  "as forgiving as before the fix," never a new regression.) (#1)
- `_config_to_int` (`lib/config.sh`) now emits a one-line stderr warning
  when a numeric config value is outright rejected and its default is
  substituted (e.g. `bashauma: config key 'aging_seconds' has invalid
  value "5m" — using default 300`). A valid-but-fractional value still
  truncates silently with no warning — that distinction is unchanged.
  Warnings are readable via `herdr plugin log list --plugin bashauma`,
  confirmed against the installed herdr binary as the only route to a
  plugin script's stderr. (#2)

## 1.0.0

Full scheduler rewrite per `prd.md`, correcting v0.1's core mistake: it
shipped both a scheduler (good) and an interrupt handler (bad).

### Added

- Priority-class ready queue: **P0 (blocked)** before **P1 (idle/done,
  hungry)**, per `prd.md` §6.2.
- Bottom-anchored `blocked` confirmation (`pane read --source visible`,
  configurable `blocked_confirm_lines` / `blocked_confirm_pattern`) before a
  `blocked` pane is trusted as P0 — herdr's own signal is noisy per agent
  (measured against Copilot CLI, `prd.md` §14).
- False-claim demotion: a P0 pane the user leaves without dispatching is
  demoted to P1 for the epoch; `p0_suppress_after_demotions` demotions
  (default `3`, configurable) permanently suppress its P0 eligibility.
- Affinity ranking (`tab` / `workspace` / `none`, config `affinity`) to
  prefer cheap context switches over expensive ones.
- Aging: a P1 candidate waiting past `aging_seconds` is promoted above P0 so
  it can't be starved.
- New explicit-yield entry point: the `next` `[[actions]]` manifest entry
  and `next.sh`, plus a documented user-side `[[keys.command]]` keybinding
  snippet (herdr plugin manifests cannot ship key bindings themselves).
- Epoch model (`lib/state.sh`: `epoch_fed_pane_ids`, `p0_demoted_pane_ids`,
  `p0_suppressed_pane_ids`, `demotion_count`, `winner_fired_epoch`,
  `last_winner_pane_id`, `last_winner_was_p0`) replacing v0.1's
  `round.json`/`pane_status.json` pair.
- JSON configuration at `$HERDR_PLUGIN_CONFIG_DIR/config.json`
  (`lib/config.sh`) — `mode`, `aging_seconds`, `affinity`, `parked_panes`,
  `blocked_confirm_lines`, `blocked_confirm_pattern`, `blocked_confirm`,
  `p0_suppress_after_demotions` — each with a `BASHAUMA_<KEY>` environment
  override.
- Numeric config coercion: `aging_seconds`, `blocked_confirm_lines`, and
  `p0_suppress_after_demotions` truncate valid fractional values toward
  zero and silently fall back to their compiled-in default on non-numeric
  or empty input, instead of crashing the scheduler on a config typo.
- Dependency-free `bash`/`jq` test suite under `tests/` (`run_tests.sh`,
  fake `herdr` CLI stub, one case file per PRD requirement group).

### Changed

- `min_herdr_version` raised to `0.8.0`.
- Non-dispatch status changes (`working → idle/done/blocked`, or any other
  transition) now only update bookkeeping and never move focus — this is a
  hard invariant, not a default that can be turned back on.
- `mode = "off"` disables only the automatic dispatch-yield path; the `next`
  action keeps working regardless, per `prd.md` §6.8.
- Hardened on-disk state: `$HERDR_PLUGIN_STATE_DIR` and its lock directory
  are now created `chmod 700`, and `state.json` is written `chmod 600`.


### Removed

- **Finish-focus.** The v0.1 behavior of redirecting focus to an agent that
  just transitioned out of `working` is gone outright. Users who liked being
  pulled to a finished agent should install a notification plugin instead —
  that is the correct surface for it (`prd.md` §11).
- **Viewport-diffing activity detection** (`pane_is_active()` and the
  "is the user visibly busy" heuristic used to gate finish-focus) — removed
  along with finish-focus, since nothing in v1 needs it.
- The round-based `round_done_pane_ids` model, replaced by the epoch/
  priority-class state above.
- `BASHAUMA_ACTIVITY_CHECK_SECONDS` — no replacement; there is no more
  activity detection to configure.

## 0.1.0

Baseline release.

### Added

- `on_status_changed.sh` event hook reacting to `pane.agent_status_changed`,
  with two behaviors: round-based dispatch tracking (redirect focus to the
  next undone pane in a round, celebrate with a winner popup once every open
  pane has a task) and finish-focus (redirect focus to a pane that just
  finished, unless the user's current pane showed recent activity).
- Viewport-diffing activity detection (`pane read --source visible`
  snapshots compared a short interval apart) to decide whether the user
  looked "busy" before finish-focus redirected them.
- `winner_screen.sh` ANSI confetti popup.
- `HERDR_PLUGIN_STATE_DIR`-backed `round.json` / `pane_status.json` state,
  serialized with an `mkdir`-based atomic lock.
- `BASHAUMA_DEBOUNCE_SECONDS`, `BASHAUMA_ACTIVITY_CHECK_SECONDS`,
  `BASHAUMA_LOCK_STALE_SECONDS` environment knobs.
