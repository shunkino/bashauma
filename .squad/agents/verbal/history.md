# Verbal History

## Project context

- Project: herdr extension
- Delivery style: lightweight and shell-first
- Publishing goal: a clean, contributor-friendly public repository
- Quality bar: standard review and validation, with clear docs
- User: Shun Kinoshita

## Initial orientation

- Keep docs aligned to the actual repo workflow.
- Prefer clear, concise instructions over process-heavy documentation.
- Support a publish-ready repository with obvious onboarding and release guidance.

## 2026-08-18T22:37:23+09:00: README/CHANGELOG rewrite for v1

Rewrote `README.md` end-to-end for v1 (the v0.1 doc still described
finish-focus/viewport activity detection, which is gone) and added
`CHANGELOG.md` with `1.0.0` and `0.1.0` entries. Read `prd.md` in full plus
the shipped code (`herdr-plugin.toml`, `on_status_changed.sh`, `next.sh`,
`lib/state.sh`, `lib/config.sh`, `lib/scheduler.sh`, `winner_screen.sh`,
`tests/README.md`) and all three inbox decisions (Keaton's plan, Hockney's
harness, Fenster's implementation-complete note) before writing.

Verified against code rather than trusting the prompt or prd.md:
- `lib/config.sh`'s `CONFIG_DEFAULT_JSON` and every `BASHAUMA_<KEY>` env
  override — all 7 config keys and defaults documented match exactly
  (`mode=on`, `aging_seconds=300`, `affinity=tab`, `parked_panes=[]`,
  `blocked_confirm_lines=5`, `blocked_confirm_pattern`=built-in regex,
  `blocked_confirm=true`).
- `herdr-plugin.toml`: no `[[keybindings]]` table exists (confirms Keaton's
  finding) — documented the user-side `[[keys.command]]` snippet and
  `herdr plugin action invoke next` as the way to test without a binding.
  `min_herdr_version = "0.8.0"` (bumped README's stated requirement from
  v0.1's 0.7.0).
- `on_status_changed.sh`: confirmed `mode = "off"` gates only the dispatch
  path, not `next.sh` — documented this explicitly per Fenster's flagged
  finding, since it's easy to misread from prd.md §6.8 alone.
- `BASHAUMA_DEBOUNCE_SECONDS` (on_status_changed.sh) and
  `BASHAUMA_LOCK_STALE_SECONDS` (lib/state.sh) are separate from the
  config.json knobs — kept them documented in their own small table so
  readers don't conflate plugin-internal timing with scheduling policy.

Migration section calls out `BASHAUMA_ACTIVITY_CHECK_SECONDS` removal (no
replacement — no more activity detection to configure) and the outright
removal of finish-focus/viewport-diffing, pointing users at notification
plugins instead, per prd.md §11.

No code/doc mismatches found beyond the already-known, already-documented
`min_herdr_version` bump (0.7.0 → 0.8.0) and the intentional TOML→JSON
config format change — both are deliberate v1 changes, not bugs. Did not
touch `prd.md`, `tests/`, `lib/`, `on_status_changed.sh`, `next.sh`,
`winner_screen.sh`, or `herdr-plugin.toml`.

## 2026-08-19T01:00:22+09:00: docs sync after Hockney's review-fix cycle

Re-verified README/CHANGELOG against `lib/config.sh` after Keaton's fix pass
(`.squad/decisions/inbox/keaton-v1-review-fix.md`) closed Hockney's 2
blockers. Changes affecting docs, all confirmed by reading the current code
directly (not trusting the decision note's prose):

- New config key `p0_suppress_after_demotions` (default `3`,
  `BASHAUMA_P0_SUPPRESS_AFTER_DEMOTIONS` override) — added to both the
  config table and the env-override table, and the false-claim-demotion
  paragraph updated to reference it instead of a hardcoded "three
  demotions."
- `_config_to_int` in `lib/config.sh` — documented the actual coercion rule
  (valid fractional/negative numbers truncate toward zero; anything else
  falls back to that key's own default) for the three numeric knobs it's
  applied to (`aging_seconds`, `blocked_confirm_lines`,
  `p0_suppress_after_demotions`), added right after the env-override table
  so it reads as one coherent block.
- Hardening: `lib/state.sh` now `chmod 700`s the state dir/lock dir and
  `chmod 600`s `state.json` — added a short "State storage" subsection
  under Configuration.
- Re-read `config_load()` line by line against every row of the existing
  config table and env-override table; all previously documented keys/
  defaults (`mode`, `affinity`, `parked_panes`, `blocked_confirm_lines`,
  `blocked_confirm_pattern`, `blocked_confirm`) were unchanged and still
  accurate — only the new key needed adding.
- `CHANGELOG.md`'s `1.0.0` entry updated: new config key and coercion
  behavior added under Added, hardening added under Changed.

Did not touch `lib/`, entrypoints, `tests/`, `herdr-plugin.toml`, or
`prd.md`. No new code/doc mismatches found; the locking restructure
(BLOCKER 1) and the grep-injection fix (Rai A) are internal correctness/
security fixes with no user-facing config or behavior surface, so they
don't require README changes beyond what's already covered by the existing
non-preemption/state-lock language.

📌 Team update (2026-08-18T22:37:23+09:00): README/CHANGELOG rewritten for v1 (JSON config, no shipped keybindings, two yield points) and synced again after Keaton's fix cycle (p0_suppress_after_demotions, numeric coercion, permissions) — decided by Verbal.

## 2026-08-19T10:25:41+09:00: prd.md §6.1/§7 keybinding correction (approved exception)

**What:** With explicit user approval to edit `prd.md` for this task only,
corrected two locations that claimed a herdr plugin manifest has a
`[[keybindings]]` table:

- §6.1 "Yield points" — "a manifest `[[actions]]` entry, bindable via
  `[[keybindings]]`" → "a manifest `[[actions]]` entry; the user binds a key
  to it in their own herdr config."
- §7 "API Dependencies" — "`[[actions]]` + `[[keybindings]]` — the explicit
  `next` yield." → "`[[actions]]` — declares the `next` action; the explicit
  yield's key binding is user-side config, not a plugin capability."

**Verification method:** Did not rely on Keaton's or Fenster's prior notes
alone. Independently confirmed against the live `herdr` 0.8.0-preview binary
at `/Users/shunkin/.local/bin/herdr`:
- `herdr api schema --output` dumped the full bundled API schema JSON;
  `PluginManifestAction`'s properties are exactly `id`, `title`,
  `description`, `command`, `platforms`, `contexts` — no keybinding field.
  No `PluginManifestKeybinding`-shaped `$def` exists anywhere in the schema.
- `strings` on the binary confirms `RawPluginManifest`'s own field list
  (`version`, `min_herdr_version`, `description`, `platforms`, `build`,
  `startup`, `actions`, `events`, `link_handlers`, `panes`) has no
  `keybindings` field either — only `[[keys.command]]` /
  `type = "plugin_action"` / `action_id` exist, and those are strings found
  in the *user config* parsing path (`herdr config reset-keys` backs up and
  removes custom keybindings; `Removed [keys], [keys.indexed], and
  [[keys.command]] from ...` is a migration message for the user's own
  config.toml, not a plugin manifest).
- Re-verified the rest of §7's dependency list the same way, all confirmed
  accurate and left untouched: `pane.agent_status_changed` (present in the
  binary's event-name list and as `PluginManifestEventHook.on`), `agent
  list`/`agent get`/`agent focus` (all real `herdr agent` subcommands;
  `AgentInfo` schema has `agent_status`, `state_change_seq`, `tab_id`,
  `workspace_id`, `cwd`, `focused`, `pane_id`), `plugin.pane.open` (a real
  socket request method name — found via `"const": "plugin.pane.open"` in
  the request schema, alongside `plugin.pane.close`/`plugin.pane.focus`/
  `plugin.action.invoke`/etc.), `HERDR_PLUGIN_STATE_DIR` and
  `HERDR_BIN_PATH` (both present as literal env var names in the binary).
  §7's opening claim ("All existing; no Herdr core changes required")
  remains true after the correction — the fix only changes which existing
  mechanism (`[[actions]]` + user config) is credited, it doesn't introduce
  a new one.

**README/CHANGELOG:** Already consistent — both were written against the
verified user-side-keybinding reality in the prior pass, so no further edits
were needed there.

**Scope:** `prd.md` only, matching the pre-approved exception; no other
prd.md content restructured, no changelog note added inside prd.md itself
per instructions.
