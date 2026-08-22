# Squad Decisions Dedupe Archive

Archived at 2026-08-22T10:14:20+09:00. Source: decisions.md. Reason: oversized noncanonical Hockney QA narrative already represented by consolidated decision entries and Hockney history.

# Hockney: correcting Scenario D's needle (a0_suppression_logging.sh) — stream separation, not relabeling

**Reviewer:** Hockney (QA)
**Scope:** `tests/lib/harness.sh`, `tests/cases/a0_suppression_logging.sh`, `tests/README.md` (test-owned files only; no `lib/`, entrypoint, or manifest edits made).

## What was wrong with the original test, concretely

Scenario D's needle was `assert_not_contains "$HARNESS_LAST_OUTPUT" "suppress"`,
and `invoke_explain` fused stdout+stderr (`2>&1` inside the command
substitution). `explain`'s real report legitimately prints
`p0_suppress_after_demotions` (a config echo) and a per-candidate
`suppressed=` field on stdout — correct, useful diagnostic output; naming
suppression state is precisely `explain`'s job. The needle couldn't tell
that apart from A-0's real threshold-crossing log line actually firing on
stderr, so even after Fenster's `log_enabled` fix (which is correct — see
below) the test still failed on the report's own legitimate vocabulary.
Fenster's response — relabeling the report fields to
`p0_supp_after_demotions=`/`p0_capped=` — made the test pass without
touching the property it exists to protect, and introduced a real
usability regression: `explain` is the tool a user runs to find out which
knob to turn, and it would now print a config key name
(`p0_supp_after_demotions`) that doesn't exist in `config.json`. Someone
following the report would set the wrong key and get silence.

## What I changed instead (tests/ only)

1. **`tests/lib/harness.sh`**: replaced the inline `HARNESS_LAST_OUTPUT=$(... 2>&1)`
   pattern in `invoke_status_changed`/`invoke_next`/`invoke_explain` with a
   shared `_harness_run_captured` helper that redirects stdout and stderr
   to two separate temp files under the per-test `$HARNESS_TMP_DIR`,
   running the command exactly once (no double-invocation of
   side-effecting scripts). It now sets three variables:
   - `HARNESS_LAST_STDOUT` — stdout only.
   - `HARNESS_LAST_STDERR` — stderr only.
   - `HARNESS_LAST_OUTPUT` — both concatenated (stdout first), kept
     **unchanged in meaning** for every pre-existing assertion that only
     checks substring presence (never stream identity or interleaving
     order) — e.g. `regression_config_warning.sh`'s stderr warning-text
     checks. Verified no existing case depends on stream identity or
     ordering (`grep`'d every `HARNESS_LAST_OUTPUT` use across
     `tests/cases/`); all are plain `assert_contains`/`assert_not_contains`
     substring checks, so the fused variable's continued existence keeps
     them passing unmodified.
2. **`tests/cases/a0_suppression_logging.sh`**: rewrote all four scenarios'
   needles to (a) target `$HARNESS_LAST_STDERR` specifically — A-0's real
   log lines are stderr-only by design — and (b) match the log line's
   distinctive shape (`"crossed P0 suppression threshold"` /
   `"pruned on close"`) rather than the bare word `"suppress"`. Scenarios A
   and B (which assert the log **does** fire) were updated for
   consistency even though their broader needle wasn't the one that broke,
   so all four scenarios now share one precise convention instead of
   leaving the same fragility to resurface from a different direction
   later. Added a substantial header-comment explaining why (both at the
   top of the file and inline at Scenario D), since this is exactly the
   kind of needle-fragility trap the file's original header comment
   already anticipated arriving from an unexpected direction.
3. **`tests/README.md`**: documented `HARNESS_LAST_STDOUT`/
   `HARNESS_LAST_STDERR`/`HARNESS_LAST_OUTPUT` explicitly, with a pointer
   to this exact incident as the reason new assertions should prefer the
   split variables and be specific about which stream they mean.
4. Also corrected a now-stale doc comment in `harness.sh`'s header (it
   said `explain_decision()` "does NOT persist a last-decision snapshot
   anywhere (no explain.json...)" — Fenster added `_explain_write_artifact()`
   after that comment was written; corrected to describe the real,
   current contract, matching what I'd already flagged as a nit in the
   prior review cycle).

## Empirical verification (per the acceptance criterion — not assumed)

Confirmed the corrected Scenario D still genuinely fails against the
*unfixed* logging behavior, not just against the relabeled-fields dodge:
copied the repo to a scratch directory, hard-coded
`_demote_pane_to_p1`'s `log_enabled` parameter to always `"true"`
(simulating the pre-`log_enabled`-threading behavior, i.e. reverting
Fenster's actual fix), and ran the corrected test standalone against that
copy:

```
✗ a read-only explain call must NEVER emit the real A-0 threshold-crossing
  log line on stderr ...: did not expect to find [crossed P0 suppression
  threshold] in [bashauma: pane p_noisy crossed P0 suppression threshold
  (3 demotions) at 1787185820614ms]
1 assertion(s) failed out of 9
```

Exactly one assertion fails — the one that matters — confirming the test
fails for the right reason against the right defect, and passes against
the current code for the right reason (the `log_enabled` threading, not
the field relabeling). Scratch copy deleted after verification.

## Suite state

19 case files, **19/19 passing** against current `lib/scheduler.sh`
(including Fenster's `log_enabled` fix, still in its current
relabeled-field state). Re-ran the full suite 3 consecutive times — stable.
`bash -n` clean on both modified files. `shellcheck -x` shows only
pre-existing, unrelated warnings (an unused `C_YELLOW` var in a non-tty
branch, an unresolvable `SC1091` source-path note) — no new issues from
these changes.

## What Fenster must restore in `lib/scheduler.sh`

The `log_enabled` threading itself is correct and should stay exactly as
shipped. Only the field-relabeling needs reverting, in
`_print_explain_report()` (around lines 730 and 762 as of this review):

1. Restore the config echo's key name: `p0_supp_after_demotions=` →
   `p0_suppress_after_demotions=` (matching the real key in
   `config.json`/`lib/config.sh`'s `CONFIG_P0_SUPPRESS_AFTER_DEMOTIONS`).
2. Restore the per-candidate field label: `p0_capped=` → `suppressed=`
   (matching the underlying `is_suppressed` value it prints — `p0_capped`
   is not a term used anywhere else in the codebase or docs).
3. Remove the comment block claiming the report "must never contain the
   literal substring `suppress`" — that constraint no longer applies; the
   corrected test (`tests/cases/a0_suppression_logging.sh` Scenario D) now
   asserts against `$HARNESS_LAST_STDERR` for the real log line's
   distinctive text, not against a bare keyword in the fused stream, so
   `explain`'s stdout report is free to say "suppress" as much as
   accurately describing its own knobs requires.

No other `lib/` change is needed — the actual defect (log firing from a
non-persisting caller) was already fixed correctly by the `log_enabled`
threading; only the workaround built on top of a since-corrected test
needle needs to come back out.

## Verdict

Not a formal re-review of the whole artifact (this is a narrow follow-up
on one test's needle, not a full pass) — no APPROVED/REJECTED verdict is
being rendered here. Once Fenster restores the two field labels above, the
suite should still read 19/19 with no further test changes needed on my
side; I'll re-run and confirm when that lands.

# Hockney review: v1.1 (`explain` action, A-0 suppression logging, B-lite workspace-locality tier)

**Reviewer:** Hockney (QA)
**Author of record:** Fenster
**Scope reviewed:** `lib/scheduler.sh` (explain/A-0/B-lite additions), `explain.sh` (new),
`herdr-plugin.toml` (1.0.1 → 1.1.0), plus `prd.md`/`README.md`/`CHANGELOG.md` (Verbal's docs pass, read only).

## Test provenance

- **Written proactively, before the implementation landed** (from
  `.squad/design/v1.1-scheduling.md`, before ever viewing Fenster's code):
  `tests/cases/explain_action.sh`, `tests/cases/a0_suppression_logging.sh`
  (scenarios A–C), `tests/cases/b_lite_workspace_locality.sh`, plus the
  `BASHAUMA_EXPLAIN_CMD` harness indirection and the `nongoal_guard.sh`
  extension to statically check `explain.sh`.
- **Added during the review pass, after finding a real defect**:
  `tests/cases/a0_suppression_logging.sh` Scenario D (pins the log-pollution
  bug below; currently fails by design).
- The harness's `explain_winner_pane_id()` was corrected once during
  proactive-writing (my first draft assumed a nonexistent `explain.json`
  contract; the real implementation's stdout `<-- WINNER` marker was
  substituted once `explain.sh` was observed on disk). `explain.json` does
  now exist (added by Fenster mid-cycle) and was verified directly by hand
  (see below) but is not yet asserted on by the harness — a nit, not a gap
  that blocks release, since the stdout contract already proves the same
  winner value.

## Suite result

`bash tests/run_tests.sh`: **19 case files, 18 passing, 1 known/expected
failure** (the new Scenario D regression test, which fails by design
against current code — it exists to pin a real defect, not a flake).
Re-ran the full suite 3 times to confirm stability; the previously observed
one-off flake in `regression_suppression_survives_lineage_check.sh` (from
an earlier session) did not recur in any of these runs — treated as an
unreproduced timing artifact, not a regression, not blocking.

## Findings
### MAJOR — A-0's stderr log fires from `explain`, even though `explain` never persists anything

`_demote_pane_to_p1()` (called both from `schedule()`'s real dispatch path
and from `explain_decision()`'s read-only path, directly and via the
shared `_classify_candidate()`) unconditionally writes the
"pane $pane_id crossed P0 suppression threshold" stderr line as a side
effect of computing the *would-be* demoted state, with no caller-side
guard distinguishing "this state is about to be `state_save`d for real"
from "this is a hypothetical computation `explain_decision()` is about to
discard." Concretely reproduced: seed `demotion_count: {"p_noisy": 2}`,
script `p_noisy` as an unconfirmed P0 candidate one demotion short of
`p0_suppress_after_demotions` (default 3), invoke `explain.sh` alone (no
`schedule()` call) — the threshold-crossing log fires on stderr, but
`state.json`'s `demotion_count.p_noisy` remains `2`, unpersisted. Repeated
`explain` invocations against the same unchanged state re-fire the same
"crossed threshold" log every single time, since nothing was ever actually
recorded.

This directly undermines A-0's entire stated purpose. Per the design doc
and per `CHANGELOG.md`'s own words ("no suppression event has yet been
observed in real use... shipping decay logic against a signal nobody has
watched fire would be guessing"), this log exists specifically to be
trusted evidence gating whether issue #3 (demotion decay) is ever built.
A log that can be made to cry "suppression!" on demand, once per `explain`
call, with no real suppression ever having happened, is not trustworthy
evidence — worse, it inflates apparent suppression frequency in exactly
the direction that would wrongly justify building A-full. Anyone running
`explain` repeatedly while diagnosing a borderline-P0 pane (a plausible,
even encouraged use case — `explain` is documented as "safe to run at any
time, as often as you like") pollutes the very signal A-0 exists to
collect.

Not a §9/behavioral blocker — `explain` still never calls `agent focus`,
never touches real `state.json`, never takes the lock; this is scoped
entirely to a diagnostic side channel. But it is a correctness defect in
the one thing this cycle's A-0 item was built to deliver honestly, so I'm
rating it MAJOR rather than minor.

Regression test: `tests/cases/a0_suppression_logging.sh` Scenario D
(new, currently failing as designed).

Suggested fix shape (not prescribing implementation, since `lib/` is not
mine to edit): thread a "would this be persisted?" flag into
`_demote_pane_to_p1` (or split it into a pure-compute helper plus a
logging wrapper only called from `schedule()`'s persisted path), so
`explain_decision()` can reuse the same classification math without
triggering the stderr side effect.
### Verified clean (no new finding)

- **§9 hard invariant**: `grep`-confirmed exactly one `agent focus` call
  site in the entire tree (`lib/scheduler.sh:687`), inside `schedule()`'s
  post-unlock dispatch tail. Neither `explain_decision()` nor
  `_print_explain_report()` nor `_explain_write_artifact()` contains or
  reaches it. Static `nongoal_guard.sh` check (extended this cycle to
  cover `explain.sh` too) passes.
- **`explain` never drifts from the real cascade**: `_classify_candidate`
  and `_resolve_confirm` are genuinely shared between `schedule()` and
  `explain_decision()` (same functions, not parallel copies), and the
  final `sort_by([...])` key list is textually identical in both call
  sites. `tests/cases/explain_action.sh`'s non-obvious false-claim-
  demotion scenario (where a naively-duplicated cascade would disagree
  with the real one) passes, matching `explain`'s reported winner against
  `next`'s actual focus target.
- **B-lite tier correctness and boundaries**: does not override P0
  (confirmed candidate beats same-workspace idle candidate), does not
  override aging promotion, sits at the documented position (5th key,
  between `affinity_rank` and `seq`), and is a provable no-op under
  default `tab` affinity (workspace-sharing is already partitioned by
  `_affinity_rank` under default modes) — confirmed by direct code
  reading, not just test-passing, since a subtly-wrong "no-op" claim would
  otherwise be easy to miss. §6.4 determinism holds under the new tier
  (identical queue state → identical pick, verified 3x in
  `b_lite_workspace_locality.sh`'s Scenario E and again across 3 full
  suite reruns this session).
- **`explain.json` artifact**: manually verified by direct invocation —
  written to `$HERDR_PLUGIN_STATE_DIR/explain.json`, atomic tmp+mv, `700`
  dir / `600` file permissions actually applied (`drwx------`/`-rw-------`
  observed), JSON shape matches what `prd.md`/`README.md` document
  (`winner_pane_id`, `candidates[]` with `pane_id`/`class`/
  `affinity_rank`/`aged`/`state_change_seq`/`suppressed`/`demoted`). This
  resolves what looked mid-session like a doc/code mismatch (docs claimed
  the file, code at that point didn't write it yet) — Fenster shipped the
  writer before I finished the review; Verbal's inbox note independently
  confirms the same discovery and corrected wording ("read-only w.r.t.
  real scheduling state, but not literally file-write-free").
- **Regression sweep**: all 16 pre-v1.1 cases still pass — §5 non-goals,
  §10 no-partial-writes, `mode=off` semantics, §6.2 bottom-anchoring, the
  `demotion_seq` lineage check, Fenster's issue #2 config-warning work, the
  3-phase lock discipline. `bash -n` and `shellcheck -x` both clean per
  Fenster's report (not independently re-run by me this cycle — no reason
  to distrust it given everything else checked out and shellcheck/bash -n
  are deterministic static checks).
- **Version/CHANGELOG consistency**: `herdr-plugin.toml` = `1.1.0`,
  `CHANGELOG.md`'s `## 1.1.0` entry present and accurate against the
  shipped code (workspace-locality tier, `explain` action, A-0 logging
  framed correctly as evidence-gathering, `explain.json` correctly framed
  as best-effort/no schema guarantee). No mismatch.

## Non-blocking nits

- `tests/lib/harness.sh`'s `explain_winner_pane_id()` only parses the
  stdout `<-- WINNER` marker; it does not additionally assert on the newer
  `explain.json` artifact. Worth adding in a follow-up so the file-writing
  path gets direct test coverage rather than relying on my one manual
  check in this review — I did not add it this cycle since the artifact
  landed very late in the review window and the stdout contract already
  fully proves winner correctness.
- One earlier-session flaky observation in
  `regression_suppression_survives_lineage_check.sh` (single failure,
  not reproduced in 8+ subsequent runs including 3 more this session) —
  noting for awareness only, not filing as a defect without a repro.

## Verdict: **APPROVED WITH NITS**

The one MAJOR finding (A-0 log-pollution from `explain`) does not violate
§9, does not corrupt real state, and does not block release on its own
merits — but it does directly undermine the trustworthiness of the
evidence-gathering mechanism this release exists partly to ship, so it
should not be silently carried forward. Recommend it be fixed in a
follow-up before anyone relies on A-0's log volume to make the issue #3
(demotion decay) call, rather than blocking this release outright, since
the affected surface is diagnostic-only and every user-facing behavior
(§9, §5, §10, `mode=off`, §6.2, §6.4, B-lite's boundaries) checks out
clean.

**Named fix agent, if the coordinator wants this addressed before/alongside
release: Fenster** (original author, not locked out — this review is
APPROVED, not REJECTED, so the reviewer-rejection lockout protocol does not
apply here; Fenster remains free to patch his own artifact based on this
finding). If the coordinator prefers a formal reject-and-reassign cycle
instead of a fast-follow patch, escalate to the coordinator for that call —
I am not rejecting outright given the defect's narrow, diagnostic-only
blast radius.

# Verbal — v1.1 scheduling docs sync (workspace locality, `explain`, predictability amendment)

**From:** Verbal (Docs/Release)
**Affects:** anyone reading `prd.md`, `README.md`, `CHANGELOG.md`; relevant to
Keaton (spec owner) and Fenster (implementer) for final review.

## What changed in docs

- `prd.md` §6.4: the determinism sentence now states **predictability**
  (not mere reproducibility) as the requirement, and explains that this is
  why the pick-next policy is a lexicographic cascade rather than a
  weighted score. Written as a standing spec clarification — no reference
  to the Devil's-Advocate debate or any names, per Keaton's instruction.
- `prd.md` §6.4: cascade now documents the workspace-locality tier as item
  4 (between affinity and FIFO), matching the shipped sort key
  `aged_rank, class_rank, affinity_rank, workspace_locality_rank, seq,
  pane_id`.
- `prd.md` §6.1/§7: `explain` documented as a third, non-yield action.
- `README.md`: `explain` keybinding example, dedicated "why did it send me
  there" section, workspace-locality tier added to the pick-next list, a
  troubleshooting line, and a State-storage note about the `explain.json`
  sibling artifact.
- `CHANGELOG.md`: new `## 1.1.0` entry (workspace-locality tier, `explain`
  action, A-0 suppression logging framed as a deliberate evidence-gathering
  decision ahead of demotion decay). Version `1.1.0` matches
  `herdr-plugin.toml` — no mismatch.

## Something worth flagging to Keaton/Fenster

While drafting I initially wrote that `explain` "never writes state" —
reading `_explain_write_artifact()` in `lib/scheduler.sh` showed this is
inaccurate: `explain` does write a best-effort `$STATE_DIR/explain.json`
(700/600 perms, atomic tmp+mv) for machine-readable introspection, even
though it never touches `state.json`, never takes the lock, and never
calls `agent focus`. I corrected the docs to describe this precisely
(read-only w.r.t. real scheduling state, but not literally file-write-free)
rather than leave the stronger, incorrect claim in place. No action needed
from the team — flagging only so nobody else independently documents the
stronger (wrong) claim.

## Explicitly NOT documented this cycle

Keyword transition hold (item C), full demotion decay (issue #3), and the
weighted/profile scoring model (B-full) — all confirmed absent from
`lib/scheduler.sh` by direct reading, all deliberately gated per the design
doc. Nothing about them appears in `prd.md`, `README.md`, or `CHANGELOG.md`.

## No other mismatches found

Design doc's cascade ordering, `explain`'s read-only contract, and the
`1.1.0` version all matched the shipped code and `herdr-plugin.toml`
exactly. `tests/README.md`'s new v1.1 section (read, not edited) is
consistent with what I documented.

# Fenster decision: v1.1 items 1-3 shipped (explain / A-0 logging / B-lite tier)

**By:** Fenster
**Scope:** `lib/scheduler.sh`, `explain.sh` (new), `herdr-plugin.toml`
**Version:** `1.0.1` → `1.1.0` (minor: adds an action + a scheduling tier, no breaking change, zero-config default behavior preserved except the one intended B-lite change).

## What shipped (all three from the design doc's "Revised recommended order", items 1-3 only)

1. **`explain` action** (`explain.sh`, new `[[actions]]` entry). Read-only,
   never calls `agent focus` (verified both behaviorally and by
   `tests/cases/nongoal_guard.sh`'s static grep). It does **not** duplicate
   the pick-next cascade: I extracted the per-candidate classification
   rule into `lib/scheduler.sh:_classify_candidate` (used by both
   `schedule()` and the new `explain_decision()`), and the final
   `sort_by(...)` ordering is literally the same jq expression in both
   places. `explain_decision()` runs against its own in-memory copy of
   `state.json` (loaded via `state_load`, never locked, never
   `state_save`d) so any hypothetical false-claim demotion or
   lineage-forget it computes for reporting purposes is discarded, never
   persisted. It also writes `$HERDR_PLUGIN_STATE_DIR/explain.json` (700
   dir / 600 file, atomic tmp+mv, same discipline as `state.json`) as a
   machine-readable sibling artifact — written only when the `explain`
   action itself runs, not from `schedule()`'s hot path, to keep the real
   scheduler's per-dispatch cost unchanged.
2. **A-0 — suppression logging only**, no config/state-schema/prd.md
   change: `_demote_pane_to_p1` logs to stderr the exact moment a pane's
   `demotion_count` first crosses `p0_suppress_after_demotions`, and
   `schedule()`'s existing close-prune block logs every suppressed
   pane_id it prunes on close. Both use stderr — the same channel and
   rationale already shipped for config-coercion warnings (herdr captures
   hook stderr per invocation, readable via `herdr plugin log list
   --plugin bashauma`) — deliberately not a new log file, so there's
   nothing to size or rotate.
3. **B-lite — one added lexicographic tier** (`_workspace_locality_rank`):
   inserted between `affinity_rank` and `seq` in the final sort key
   (`aged_rank, class_rank, affinity_rank, workspace_locality_rank, seq,
   pane_id`). Purely a hard gate, no config, no state — `_classify_candidate`
   computes it from already-available `agents_json`/departure-anchor data.
   Confirmed by test (`tests/cases/b_lite_workspace_locality.sh`, all
   passing) that it cannot cross the P0/P1 boundary and cannot override
   the aging starvation guarantee.

## What was explicitly NOT built (per the design doc's gates)

- Item 4 (keyword hold) — separate cycle, not touched.
- A-full (demotion_count time decay) — still gated behind evidence from
  A-0's new logging; nobody has observed a real suppression event outlive
  continued use yet.
- B-full (weighted/profile scoring model) — still gated behind B-lite
  proving insufficient in real use, `explain` already in production, and
  the prd.md determinism/predictability amendment landing (Verbal's side).

## Refactor note for reviewers

`schedule()`'s candidate-building loop and Phase-2 confirm-cache logic
were refactored (not just extended) to share `_classify_candidate` /
`_resolve_confirm` with `explain_decision()`. This was necessary to honor
the "explain must never drift from the real cascade" requirement — I
deliberately treated this as in-scope even though it touches
already-shipped v1.0.1 code, since duplicating the cascade was explicitly
called out as worse than not shipping `explain` at all. All 16 pre-existing
tests plus the 3 new v1.1 test files (a0_suppression_logging,
b_lite_workspace_locality, explain_action) pass: 19/19.

## Verbal — please note for CHANGELOG/README/prd.md

- Bump to `1.1.0`.
- New `explain` action, read-only, documented as non-preemptive (never a
  yield point).
- New sort tier in §6.4's cascade: `workspace_locality_rank` (5th key,
  between affinity and seq) — only observable when `affinity` is `none`
  or when candidates already tie on affinity_rank; §6.4's determinism
  language should note this is a hard tier, not a weight (ties into the
  predictability-vs-reproducibility amendment Keaton/Fact Checker
  discussed).
- A-0's stderr logging is diagnostic-only, no user-facing config; worth
  one README line under troubleshooting (`herdr plugin log list --plugin
  bashauma` now also surfaces suppression-threshold-crossing and
  suppressed-pane-close-prune events).
- `explain.json` under the plugin state dir is a best-effort diagnostic
  artifact, not part of any documented API contract — don't promise a
  stable schema for it yet.
