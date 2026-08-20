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

## Session: design-only proposal for issue #3 decay, weighted priority model, keyword hold (2026-08-19T22:29:20+09:00)

- Task: design (no implementation) for three related requests from Shun --
  issue #3 (`demotion_count` decay), a richer/dynamic priority model
  (agent-human data locality, mining the OS analogy per prd.md §12), and a
  keyword-based transition hold (departure-pane guide text vetoes the
  automatic dispatch-yield move) -- delivered as one coherent design, not
  three bolt-ons. Fact Checker separately stress-testing the premise in
  parallel.
- Read `gh issue view 3` in full, `prd.md` end to end, and `lib/scheduler.sh`
  (568 lines) + `lib/config.sh` in full before designing, to ground every
  recommendation in the actually-shipped v1.0.1 mechanics rather than
  prd.md's higher-level prose.
- **Issue #3:** recommended time decay (lazy, window-based decrement of
  `demotion_count`, new `last_demotion_at` map, new
  `demotion_decay_seconds` config default 900s), deriving `is_suppressed`
  from the counter instead of maintaining a separate
  `p0_suppressed_pane_ids` array (removed -- decay would otherwise need two
  synchronized sources of truth). Rejected the issue's own favored option
  (success-based reset) after tracing the code and confirming suppressed/
  demoted panes are classified P1 directly and never call `confirm_p0`
  again -- the "free" signal the issue assumed exists for this case does
  not exist. Threaded through issue #1's lineage check (`_forget_stale_pane`
  must also wipe `last_demotion_at`).
- **Priority model:** proposed a hybrid -- two hard bands (aged-P1 first,
  for §9's starvation guarantee) stay fixed logic; everything else (P0 vs
  non-aged P1, affinity/throughput/cheapness/staleness) becomes a weighted,
  summed score with defaults chosen so ordering is provably identical to
  today's cascade (zero-config preserved). New signals: continuous
  affinity (replacing the discrete rank), a throughput EMA (MLFQ idea,
  piggybacked on already-instrumented `record_status`/`schedule`
  transitions, no new herdr calls), a cheapness/SJF proxy reusing the
  existing P0-confirmation `pane read` at zero extra cost (line-count
  heuristic), and staleness (weighted lowest by design, since aging already
  owns starvation-freedom). Config surface: named profiles
  (`classic`/`locality`/`throughput`/`custom`) over a raw `priority_weights`
  object. Proposed a new `explain` action/manifest entry as the
  inspectability answer to the determinism-vs-predictability distinction
  the task insisted on.
- **Keyword hold:** applies only to the dispatch yield, never the explicit
  `next` yield (identified overriding an explicit user action as the
  primary failure mode to avoid; this also makes `next` the escape hatch
  for free). Checks the departure pane's own bottom-anchored text for
  `hold_keywords` (empty by default -- judged a wrong default as worse than
  none) via fixed-string, not regex, matching (plus an optional
  `hold_pattern` override). A held pane still counts as fed; only the final
  `agent focus` call and `last_winner_*` bookkeeping are skipped. Self-
  correction reuses A's decay helper (generalized to a second map) and
  issue #1's exact lineage pattern (`hold_seq`) rather than inventing a
  parallel mechanism -- the concrete form of "one model, not three
  bolt-ons" the task asked for. Argued explicitly (not assumed) that a hold
  composes with §9's non-preemption invariant, since it produces no
  `agent focus` call at all.
- Delivered full pseudocode, state schema deltas (`last_demotion_at`,
  removal of `p0_suppressed_pane_ids`, `hold_count`/`last_hold_at`/
  `hold_seq`, throughput/staleness maps), config defaults and coercion
  notes, risk assessment per item, and a recommended implementation order
  (A -> C -> B, ~0.5 / ~1 / ~3-5 days) in-session to the requester.
- Flagged prd.md revision scope per item: A = small (one §6.4 sentence),
  B = major (§6.4 policy rewrite, §6.8 config table, §6.1/§7 new action,
  §12 status update), C = moderate (§6.5 third case, §6.8 rows, §9
  compatibility sentence) -- none of the three ships without touching the
  spec of record except possibly A in isolation.
- Wrote
  `.squad/decisions/inbox/keaton-decay-priority-hold-design.md` for the
  team.
- No source files were created or modified (design-only task); did not
  edit `tests/`, `README.md`, `CHANGELOG.md`, or `prd.md`.

## Session: persist design + respond to Fact Checker's Devil's Advocate brief (2026-08-19T22:39:29+09:00)

- Task: persist the full design proposal above (previously only in-session
  context) to `.squad/design/v1.1-scheduling.md`, then read Fact Checker's
  independent Devil's Advocate brief
  (`.squad/decisions/inbox/fact-checker-devils-advocate-abc.md` +
  `.squad/agents/fact-checker/history.md`) and respond to each objection
  directly in a new section of that document, conceding where warranted
  rather than defending the original design by default.
- Wrote the complete, uncompressed proposal (model, config, pseudocode,
  state schema deltas, risks, original order/prd.md scope for A/B/C) to
  `.squad/design/v1.1-scheduling.md`.
- Verified Fact Checker's key factual claim independently before
  responding: `git show -s --format='%H %ci' 747db7e` confirms the
  lineage/suppression fix landed 2026-08-19 22:14:48, ~15 minutes before
  his brief was requested -- his "issue #3 is speculative, zero real
  triggers" point checks out exactly as stated.
- Conceded, point by point, in a new "Response to the Devil's Advocate
  brief" section:
  1. prd.md §6.4 conflates reproducibility with predictability -- agreed
     this is the crux. Under `classic` default weights (as originally
     specified, with strict tier separation) the score is provably
     behaviorally identical to today's cascade, so predictability is
     preserved *only* under that profile; any tuned profile genuinely
     erodes it, and `explain` does not rescue that (post-hoc diagnostic,
     not a pre-hoc guarantee) -- stated this plainly rather than let the
     original design imply `explain` was a substitute.
  2. Conceded to the narrower recommendation: ship Shun's literal stated
     example (workspace-locality-when-idle) as one additional
     lexicographic tier, not raw weights + named profiles. Specified the
     exact revised cascade (`aged_rank, class_rank, affinity_rank,
     workspace_locality_rank, seq, pane_id`).
  3. Conceded C's original 3-strike raw hold-count self-correction
     under-specified visibility for a single false hold (silent, unlike a
     loud false P0) and didn't use as sharp a signal as false-claim
     demotion's contradicting-user-action trigger. Redesigned: mandatory
     stderr logging of every hold event (not just repeats, reusing the
     existing config-warning log channel -- can't be a proactive
     notification, §5 forbids that surface), and replaced the raw
     3-strike counter with a `false_hold_count` incremented only when the
     user presses `next` on the held pane within
     `hold_quick_next_seconds` (new config, default 30) of the hold firing
     -- direct evidence the hold was wrong, exempting after 1 occurrence
     instead of 3. Held ground on one point: the needed §9 amendment
     clarifies "move" vs. "suppressed move," it does not weaken the
     invariant, and a literal time-based auto-expiry that later moves
     focus on its own would itself violate §5 -- clarified this rather
     than conceding a design flaw that isn't one.
  4. Fully conceded issue #3 decay logic is premature given the verified
     15-minute-old mechanism with zero real triggers. Replaced "build
     decay now" with a near-zero-effort logging-only step (A-0): log every
     suppression-threshold crossing and suppressed-pane close-prune, no
     state/config/prd.md change, and gate full decay logic behind real
     data from that log.
  5. Conceded the complexity-budget critique of bundling A+B+C into one
     cycle atop a ~12-hour-old scheduler; addressed by the revised,
     heavily evidence-gated order rather than by argument.
  6. Agreed `explain` must ship early, and extended the reasoning: the
     need is triggered by A's decay (non-obvious, time-dependent state)
     before B ships anything, not by B specifically -- moved `explain` to
     the front of the revised order.
- Revised implementation order: `explain` (minimal) -> A-0 (logging only)
  -> B-lite (one added tier + prd.md amendment) -> C (hardened per above)
  -> [gated, deferred] full demotion decay -> [gated, deferred] full
  weighted/profile scoring model (B-full). Added a low-cost addition not
  in Fact Checker's brief: log (don't act on) throughput-EMA/cheapness
  telemetry now, at near-zero cost, so B-full's saturation constants are
  evidence-based if/when its gate ever clears -- holding my own deferred
  idea to the same evidentiary standard I applied to A.
- Stated explicitly where I still hold a position rather than fully
  converging: B-full should stay on record as a named, gated future
  direction with concrete re-entry conditions, not be discarded outright
  as an idea -- argued this is a narrow disagreement about whether a
  deferred idea needs a written re-entry condition, not a disagreement
  about risk acceptance, and is consistent with Fact Checker's own "none
  of A/B/C is unreasonable to explore" framing.
- Updated `.squad/decisions/inbox/keaton-decay-priority-hold-design.md`'s
  summary to point at the persisted document and reflect the superseding
  revised order/concessions, rather than leaving the original (now
  partially retracted) summary as the team's only record.
- No source files were created or modified (design-only task); did not
  edit `tests/`, `README.md`, `CHANGELOG.md`, or `prd.md`.
