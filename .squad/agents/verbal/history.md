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

## 2026-08-19T21:44:20+09:00: v1.1 follow-up docs sync (issues #1, #2)

**What:** Read `gh issue view 1`/`2` and the current `lib/config.sh` /
`lib/scheduler.sh` directly (not the issue summaries alone) before writing.

- **Issue #1 (pane-lifetime P0 suppression):** `lib/scheduler.sh`'s prune
  block now includes `p0_suppressed_pane_ids`/`demotion_count` alongside the
  other four maps, pruned against the live `agent list` set on every
  `schedule()` call. Fenster's comment there is explicit that this is a
  deliberate reading of §6.4 ("survives an epoch" ≠ "survives the pane"),
  and that herdr's `pane_id` counter is monotonic per-workspace and not
  reused within a running session (confirmed empirically per the comment),
  so in practice this only differs from "permanent" across an actual pane
  close or a herdr server restart. Updated README's false-claim-demotion
  prose and the `p0_suppress_after_demotions` config table row to say "for
  as long as the pane stays open" instead of "for the rest of the
  session," and corrected `prd.md` §6.4's one sentence to match (approved
  standing exception for factual prd.md corrections).
- **Issue #2 (silent config rejection):** `_config_to_int` now takes an
  optional `<key name>` and emits `bashauma: config key '<key>' has invalid
  value "<raw>" — using default <fallback>` to stderr only on outright
  rejection (non-numeric, scientific notation, empty, null) — a valid
  fractional value still truncates silently, no warning, matching existing
  README language. Documented both paths explicitly as separate bullets so
  the silent/warned distinction isn't glossed over. Added a "my config
  isn't taking effect" Troubleshooting entry pointing at `herdr plugin log
  list --plugin bashauma`, per Fenster's comment confirming (against the
  live installed binary) that plugin-script stderr is captured per
  invocation and retrievable there, not printed to the terminal or
  otherwise visible.
- **CHANGELOG.md:** added `1.0.1`, not `1.1.0` — both changes are fixes to
  already-shipped v1.0.0 behavior (unbounded state growth, silent
  misconfiguration), add no new config keys/commands, and don't change the
  documented contract in a way users need to opt into. That reads as patch,
  not minor, under ordinary semver judgment.
- **Flag for the team:** `herdr-plugin.toml` still declares `version =
  "1.0.0"`; if `1.0.1` is the agreed version number, that file needs a
  matching bump — not edited here, it isn't mine to touch.

**No further code/doc mismatches found** in the two touched files beyond
what's listed above; `lib/scheduler.sh`'s and `lib/config.sh`'s comments
were detailed enough to document the shipped behavior directly from source.

## 2026-08-19T22:12:22+09:00: CHANGELOG stale-entry fix (Hockney's approval nit)

**What:** Read `.squad/decisions/inbox/hockney-keaton-lineage-fix-approved.md`
and `.squad/decisions/inbox/keaton-id-recycle-fix.md`, then read
`lib/scheduler.sh` directly (`_demote_pane_to_p1`, `_lineage_trusted`,
`_forget_stale_pane`, their wiring into the classification loop and the
false-claim path) before rewriting anything — the prior 1.0.1 CHANGELOG
entry described Fenster's rejected presence-only pruning fix, not what
Keaton actually shipped.

- Rewrote CHANGELOG's `1.0.1` issue #1 bullet: presence-based close-pruning
  is kept (still real hygiene against unbounded `state.json` growth) but
  the entry now leads with why that alone can't catch a recycled `pane_id`
  after a herdr restart, and describes the actual fix — `state_change_seq`
  used as a monotonic lineage fingerprint, `demotion_seq[pane_id]` stamped
  per demotion, trust requiring both a recorded baseline and a
  non-regressing observed seq, with either failure wiping that pane's
  history and treating it as fresh. Kept `demotion_seq` mention here since
  this *is* the state-schema-adjacent context; did not add it to README
  since README doesn't enumerate `state.json`'s schema anywhere.
  User-facing framing: a pane can no longer inherit another agent's
  distrust, so a genuinely blocked agent won't be silently skipped.
  Included Hockney's disclosed residual gap (restart-reset behavior of
  `state_change_seq` unverified without disrupting a live session, worst
  case no worse than the pre-fix bug) as a parenthetical in the same
  bullet — no natural home existed for a separate "known limitations"
  section, so didn't invent one.
- README: the false-claim-demotion paragraph and the
  `p0_suppress_after_demotions` config-table row previously said
  suppression lasts "as long as the pane stays open" — corrected to "as
  long as that pane's *identity* holds," explaining the lineage-fingerprint
  verification in plain language (no `state.json` field names beyond the
  already-config-facing `p0_suppress_after_demotions`, since `demotion_seq`
  itself is an internal implementation detail per Keaton's note).
- `prd.md` §6.4 left as-is: "repeated demotions suppress its P0 eligibility
  entirely for as long as that pane stays open — closing the pane clears
  the record" remains accurate at the spec's terse level of detail; the
  recycled-ID lineage mechanism is implementation robustness, not a change
  to the product-level rule prd.md states.
- `herdr-plugin.toml`'s `1.0.1` bump by Keaton is consistent with
  CHANGELOG's version number — confirmed, no action needed.

No further code/doc mismatches found beyond the one nit this task was
scoped to fix.

## Session: v1.1 spec amendment — predictability, workspace-locality tier, `explain` action

Read `.squad/design/v1.1-scheduling.md` in full and
`.squad/decisions/inbox/fact-checker-devils-advocate-abc.md`. Waited for
Fenster's implementation to land (background sibling `fenster-2`), then read
the final `lib/scheduler.sh` (`_workspace_locality_rank`,
`_classify_candidate`, `explain_decision`, `_print_explain_report`,
`_explain_write_artifact`, the A-0 stderr logging lines, the final
`sort_by` cascade key), `explain.sh`, and `herdr-plugin.toml` (confirmed
`version = "1.1.0"`, matching what was expected — no mismatch to flag).
Confirmed via `git diff lib/config.sh` that no config keys changed this
cycle.

Edits made:

- `prd.md` §6.4: rewrote the determinism sentence. Old text conflated
  reproducibility (identical inputs → identical output, which a weighted
  score also satisfies) with predictability (a human can anticipate the
  result without simulating the algorithm — the actual property "build
  intuition about where they will land" requires). New text states
  predictability as the explicit requirement and ties it directly to why
  the cascade is a lexicographic tier order rather than a weighted score.
  Written as a spec clarification in prd.md's existing terse voice — no
  narration of the debate, no names/credit, per Keaton's instruction that
  this correction stands on its own regardless of what else ships.
- `prd.md` §6.4: added the workspace-locality tier to the documented
  cascade as item 4 (between affinity and FIFO), matching the shipped sort
  key `aged_rank, class_rank, affinity_rank, workspace_locality_rank, seq,
  pane_id` and the design doc's placement. Described as a hard gate that
  can only break ties among candidates surviving every earlier tier.
- `prd.md` §6.1: added one paragraph noting `explain` as a third action
  that is explicitly *not* a yield point (never focuses).
- `prd.md` §7: updated the `[[actions]]` dependency line to cover both
  `next` and `explain` (no new dependency entry needed, per the design
  doc — `[[actions]]` was already listed).
- `README.md`: extended the keybinding section with an `explain` binding
  example and `herdr plugin action invoke explain`; added `explain` to the
  yield-points section as explicitly not a yield point; added the
  workspace-locality tier to "How the next pane is picked" (item 4) plus a
  paragraph on why cascades beat weighted scores (predictability); added a
  new "Why did it send me there? (`explain`)" section; added an `explain`
  line to Troubleshooting; added a note to "State storage" about the
  `explain.json` sibling artifact.
- **Correction caught during drafting**: my first pass claimed `explain`
  "never writes state" / "nothing here is persisted" — false. Reading
  `_explain_write_artifact()` showed it writes a best-effort
  `$STATE_DIR/explain.json` (700/600 perms, atomic tmp+mv, same pattern as
  `state.json`) purely for machine-readable introspection; `schedule()`
  never reads it back, so it can't affect a real decision, but it is not
  literally state-free. Corrected all three locations (prd.md §6.1,
  README's yield-points note, README's explain section, README's State
  storage note) to say "never touches the real state.json or its lock /
  never calls agent focus" instead of "writes no state," and added the
  explain.json detail explicitly.
- `CHANGELOG.md`: added a `## 1.1.0` entry (workspace-locality tier,
  `explain` action including the `explain.json` artifact caveat, A-0
  suppression-threshold/prune stderr logging framed as a deliberate
  evidence-gathering decision ahead of demotion decay/issue #3 rather than
  an omission) and a `### Changed` note for the prd.md §6.4 predictability
  clarification. Used Fenster/Keaton's version `1.1.0`, already matching
  `herdr-plugin.toml` — no mismatch to flag.
- Did NOT document anywhere: the keyword transition hold (item C), full
  demotion decay (issue #3), or the weighted/profile scoring model
  (B-full) — all confirmed absent from the shipped code by direct reading,
  all deliberately deferred per the design doc's gates.

No code/doc mismatches found this cycle beyond the one I caught and fixed
myself in drafting (the `explain.json` write). `tests/README.md`'s new
v1.1 section (read, not edited — out of scope) independently corroborates
`explain` never calling `agent focus` under any input, consistent with
what I documented.
