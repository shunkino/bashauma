# Squad Decisions

## Active Decisions

### 2026-08-20T09:00:00Z: A-0 explain log needle separation (consolidated)
**By:** Hockney
**What:** Split the test harness into separate stdout/stderr captures, rewrote A-0 assertions to target stderr and the real threshold-crossing/prune lines, and restored `explain` report labels after the harness proved the rename workaround was unnecessary.
**Why:** A fused stdout+stderr needle cannot distinguish a diagnostic log from legitimate report output. The harness now records the real A-0 evidence channel, and `explain` keeps truthful config names instead of inventing a knob that does not exist.
**Impact:** `HARNESS_LAST_STDOUT` / `HARNESS_LAST_STDERR` / `HARNESS_LAST_OUTPUT` are now available to tests; Scenario D in `a0_suppression_logging.sh` pins the real bug; the `explain` report continues to print the actual config key and `suppressed=` state label.

### 2026-08-19T22:29:20+09:00: v1.1 docs sync for explain, workspace locality, and predictability
**By:** Verbal
**What:** Updated `prd.md`, `README.md`, and `CHANGELOG.md` to document the shipped v1.1 behavior: `explain`, the workspace-locality tier, the predictability-vs-reproducibility clarification, and the `explain.json` sibling artifact.
**Why:** The docs needed to match the actual shell implementation and version bump, not the earlier design assumptions.
**Impact:** The public docs now describe the real `[[actions]]`/user-side keybinding workflow, the `1.1.0` release, and the A-0 logging/troubleshooting notes.

### 2026-08-19T23:03:24+09:00: v1.1 explain / A-0 logging / B-lite implementation
**By:** Fenster
**What:** Shipped `explain`, A-0 suppression logging, and the B-lite workspace-locality tier; extracted shared classifier helpers so `schedule()` and `explain_decision()` use the same cascade; bumped the manifest to `1.1.0`.
**Why:** The v1.1 plan needed a read-only explanation path, evidence-gathering logs for issue #3, and one additional lexicographic locality tier without introducing a weighted score.
**Impact:** `explain.sh` is now a real action, `schedule()` and `explain()` share the classification logic, and B-lite stays a hard gate rather than a config-driven scoring model.

### 2026-08-19T22:29:20+09:00: v1.1 decay / priority / hold design revision
**By:** Keaton
**What:** Reworked the original A/B/C design after the Devil's Advocate brief: moved `explain` first, reduced A to logging-only evidence gathering, changed B to a single workspace-locality tier, and hardened C rather than shipping a raw three-strike hold.
**Why:** The team accepted that predictability matters more than mere reproducibility, that A-full was premature without real suppression evidence, and that a false hold needs explicit visibility and self-correction.
**Impact:** `v1.1-scheduling.md` now documents the revised order and the evidence gates that defer A-full and B-full.

### 2026-08-19T22:29:20+09:00: Devil's Advocate brief on A/B/C
**By:** Fact Checker
**What:** Challenged the original A/B/C plan: a weighted model can be reproducible yet hard to predict, C can silently strand the user, A is speculative without real suppression evidence, and B needs an explain affordance if it ships.
**Why:** The goal was to force the design onto evidence gates before implementation, not to let the team assume the first plausible mechanism was justified.
**Impact:** The redesign converged on minimal, observable follow-ups instead of a larger three-subsystem expansion.

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

### 2026-08-19T22:29:20+09:00: design-only proposal for issue #3 decay, a weighted priority model, and keyword transition holds
**By:** Keaton
**What:** Design-only response (no source changed) covering three requested features as one coherent model rather than three bolt-ons:
- **Issue #3 (`demotion_count` decay):** recommend time decay — lazily decrement `demotion_count` by whole elapsed windows (new `last_demotion_at` map, new `demotion_decay_seconds` config, default 900s) at classification time, and **derive** `is_suppressed` from `demotion_count >= threshold` instead of maintaining a separately-written `p0_suppressed_pane_ids` array (removed from state schema — decay would otherwise require keeping two sources of truth in sync). Rejected success-based reset: traced the shipped code and confirmed a suppressed/demoted pane is classified P1 directly and **never** calls `confirm_p0` again, so the "already-computed signal" the issue assumed exists for this case does not. Composes with issue #1's lineage check: `_forget_stale_pane` must also wipe `last_demotion_at`.
- **Richer priority model:** hybrid, not a pure lexicographic cascade and not a pure score. Two hard bands stay fixed logic (aged-P1 first, for the §9 starvation guarantee); everything else (P0 vs non-aged-P1, and affinity/throughput/cheapness/staleness within/across them) becomes a weighted score (`class`, `affinity`, `throughput` (new MLFQ-style EMA of autonomous working-stretch length), `cheapness` (new SJF-proxy reusing the existing confirm-step `pane read` at zero extra cost), `staleness`), sorted descending, same final `seq`/`pane_id` tie-break. Default weights (class 1000 ≫ affinity 50 ≫ throughput/cheapness/staleness ≤5 each) are chosen so ordering is provably identical to today's cascade under defaults (zero-config preserved); named profiles (`classic`/`locality`/`throughput`/`custom`) plus a raw `priority_weights` object are the config surface. Proposed a new `explain` action (manifest `[[actions]]` entry) that prints the last scored decision from state, as the answer to "how does the user inspect a decision they can't predict by eye."
- **Keyword transition hold:** applies **only** to the dispatch yield (`on_status_changed.sh`), never to the explicit `next` yield — overriding an explicit user action was identified as the primary failure mode to avoid, and this also makes `next` the escape hatch for free. Checks the departure pane's own bottom `hold_check_lines` (new config, default 15) lines for `hold_keywords` (new config, **empty by default** — a wrong default here was judged worse than none) via case-insensitive fixed-string matching (plus an optional `hold_pattern` ERE override, mirroring `blocked_confirm_pattern`'s existing precedent). A held pane still counts as fed and all epoch bookkeeping proceeds normally; only the final `agent focus` call and `last_winner_*` state are skipped (no winner to falsify-check next time). Self-correction reuses A's decay helper generalized to a second map (`hold_count`/`last_hold_at`) plus issue #1's exact lineage pattern (`hold_seq`), rather than inventing a parallel mechanism — after `hold_suppress_after` (default 3) consecutive holds on the same pane, it becomes hold-exempt (itself decaying back over time). Argued explicitly why this composes with §9's non-preemption invariant: a hold produces no `agent focus` call at all, so it cannot cause an unrequested move — it suppresses a move the plugin's own policy would have made, not one the user asked for.
**Why:** Requested by Shun via the coordinator as a design-only deliverable for all three, explicitly asked to be "coherent as one model." All three converge on the same decaying/lineage-checked-state pattern already shipped for false-claim demotion and issue #1, which is the concrete form of that coherence (one generalized `decay()` helper, one lineage-check pattern, reused three times).
**Impact:** No source changed. Full proposal, including pseudocode, state schema deltas, and config defaults, is now persisted at `.squad/design/v1.1-scheduling.md` (not just this summary — do not treat this file as the complete record). **Superseded by that document's response to Fact Checker's independent Devil's Advocate brief** (`.squad/decisions/inbox/fact-checker-devils-advocate-abc.md`): Keaton conceded the crux objection (prd.md §6.4 conflates reproducibility with predictability; a weighted score erodes the latter under any non-default profile), conceded issue #3's decay logic is premature (verified `747db7e` shipped ~15 min before the brief, zero real triggers), and conceded C's original 3-strike self-correction under-specified visibility for a false hold. **Revised order, converged with Fact Checker: (1) minimal `explain` action first (~0.5 day, needed regardless of what else ships), (2) A-0 logging-only instrumentation for suppression events (~2 hrs, no behavior/config/prd.md change), (3) B-lite — one added lexicographic tier for workspace-locality-when-idle, not raw weights/profiles (~1 day, small prd.md §6.4 amendment), (4) C hardened with mandatory hold-event logging and a quick-`next`-triggered single-strike de-exemption replacing the raw 3-strike counter (~1.5 days).** Full demotion decay (A) and the full weighted/profile scoring model (B-full) are deferred, not rejected, behind explicit evidence gates (see the document's "Recommended path" section). Keaton held ground only on: the §9 amendment being a clarification of "move" vs. "suppressed move," not a weakening of the invariant, and on keeping B-full on record as a gated future direction rather than discarding it outright.

### 2026-08-19T22:29:20+09:00: Devil's Advocate brief on issue #3 (demotion decay), dynamic priority model (B), keyword transition hold (C)
**By:** Fact Checker (Devil's Advocate mode, requested by Shun Kinoshita, ahead of Keaton's design work)
**What:** Full brief in `.squad/agents/fact-checker/history.md`. Key findings for Keaton/team to consciously accept or reject before design proceeds:

1. **prd.md §6.4 conflates reproducibility with predictability.** A weighted/composed priority model (B) can be perfectly reproducible while destroying the "user can build intuition about where they will land" property the same sentence claims to guarantee. These are different properties and the PRD should be amended to say which one is actually required, before B's scoring model is chosen.
2. **C is not literal preemption but is the same failure family** — the plugin substituting its judgment for the user's expressed intent (a dispatch, defined by §6.1 as `sched_yield()`) by silently declining to honor it. Recommend scoping §5/§9's invariant language explicitly if C ships, and require bottom-anchored (not `whole_recent`) matching plus a self-expiring hold, reusing the exact lesson already paid for in §6.2/§14.
3. **Cost asymmetry is real and unaddressed by the current C proposal as described:** a false P0 self-corrects via demotion and is visible; a false hold under C is silent and has no proposed self-correction mechanism. This needs one before shipping.
4. **Complexity budget:** all three features are individually defensible but collectively convert a 12-hour-old, deliberately minimal scheduler into a three-subsystem configuration surface with zero production evidence of need for two of the three (B and C are motivated by single hypotheticals, not observed pain).
5. **Issue #3 (demotion decay) is speculative — verified via git log, not assumed:** the mechanism it targets (`_demote_pane_to_p1` / `p0_suppress_after_demotions` / lineage verification) shipped in commit `747db7e` at 2026-08-19 22:14:48, ~15 minutes before this brief was requested. It has never fired against real usage. Recommend a cheap logging-only step (log every `p0_suppressed_pane_ids` entry to the existing `herdr plugin log list` channel) before building decay logic, to get real data instead of guessing parameters.
6. **B requires an `explain`-equivalent affordance (`bashauma explain <pane>`) in the same release, not after**, once more than one non-gated numeric signal composes the pick — otherwise "why did it send me here?" stops being answerable, which breaks §9's own qualitative success metric. Herdr's own `agent explain` is already precedent this team relies on (used in §14's investigation).

**Why:** Requested explicitly as a pre-build Devil's Advocate pass so risks are accepted consciously, not discovered after Keaton's design lands. None of these are recommended as blockers — they are conditions attached to specific implementation choices within A/B/C.
**Impact:** None yet (no code changed). For Keaton's design of A/B/C: treat the risk-acceptance flags in the full brief as conditions to design against, not merely as review comments after the fact.
### 2026-08-18T21:09:26+09:00: herdr extension team cast
**By:** Shun Kinoshita (via Copilot)
**What:** The project is cast as a lean, shell-first team: Keaton (Lead), Fenster (Shell Engineer), Hockney (QA / Reviewer), and Verbal (Docs / Release). Built-in Squad members are active for logging, monitoring, safety, and verification.
**Why:** This repo is intended to be lightweight, shell-driven, and publication-ready, with standard testing, review, linting, and release hygiene rather than heavy project ceremony.

### 2026-08-19T21:36:10+09:00: herdr plugins cannot ship keybindings (consolidated)
**By:** Keaton, Fenster, Verbal
**What:** `herdr-plugin.toml`'s manifest schema (`RawPluginManifestAction`) has no `[[keybindings]]` table — verified live via `herdr plugin action list` against the 0.8.0-preview binary, not assumed from prd.md. Plugins may only declare `[[actions]]` (`id`, `title`, `description`, `command`, `platforms`, `contexts`). Key binding is the **user's** responsibility, added to their own `~/.config/herdr/config.toml` via `[[keys.command]]` with `type = "plugin_action"`, `action_id = "next"` (optional `plugin_id = "bashauma"` for disambiguation). bashauma's `next` action is unreachable without this user-side step, or via `herdr plugin action invoke next` for manual testing. Independently re-verified a second time by Verbal via `herdr api schema --output`/`strings` against the live binary (not just re-reading Keaton's original notes): `RawPluginManifest`'s full field list (`version`, `min_herdr_version`, `description`, `platforms`, `build`, `startup`, `actions`, `events`, `link_handlers`, `panes`) has no keybindings field anywhere, and `PluginManifestAction`'s fields are exactly `id`/`title`/`description`/`command`/`platforms`/`contexts`. This pass also corrected `prd.md` §6.1 and §7, which still claimed `[[keybindings]]` support, to match README's already-correct user-side-binding documentation.
**Why:** Trusting prd.md's assumption here would have baked in a wrong API shape. This is verified against the real CLI, not guessed — twice over, since leaving it uncorrected in prd.md (the spec of record) would have let a known-wrong claim persist even after implementation already knew better. It's also the single most important instruction for users, since without a keybinding the `next` explicit-yield action is otherwise inaccessible.
**Impact:** README.md documents the exact `[[keys.command]]` snippet plus the `herdr plugin action invoke next` fallback; `herdr-plugin.toml` ships no keybindings table; `prd.md` §6.1/§7 now match README and the manifest, and all other §7 API-dependency claims were re-verified accurate in the same pass.

### 2026-08-18T22:37:23+09:00: bashauma config is JSON, not TOML
**By:** Fenster, Verbal
**What:** Config lives at `$HERDR_PLUGIN_CONFIG_DIR/config.json` (not TOML), with full defaults per prd.md §6.8, plus a `BASHAUMA_*` environment-variable override for every knob (`mode`, `aging_seconds`, `affinity`, `parked_panes`, `blocked_confirm`, `blocked_confirm_lines`/`pattern`, `debounce_seconds`, and the newer `p0_suppress_after_demotions`). config.json remains the primary, documented mechanism; env overrides exist for one-off tuning and to drive the test harness.
**Why:** `jq` is already a hard dependency for this plugin, so JSON avoids adding a TOML parser dependency purely for config. Using JSON is strictly simpler given the existing tool footprint.

### 2026-08-18T22:37:23+09:00: mkdir-based atomic locking (no flock)
**By:** Fenster, Keaton
**What:** `lib/state.sh` locks `state.json` via a `mkdir`-based atomic lock (ported from v0.1), with a stale-lock reclaim after `STATE_LOCK_STALE_SECONDS` (default 30s) to recover from a holder that died without releasing. `state_save()` always writes via tmp-file + atomic `mv`, so unlocked readers only ever see a fully-written (possibly stale) snapshot, never a torn/partial write.
**Why:** `flock` is not present on stock macOS, so a `mkdir`-based lock is the portable choice for the target platform (bash 3.2, no bash-4+ constructs).

### 2026-08-18T22:37:23+09:00: 3-phase lock discipline in schedule() (consolidated)
**By:** Fenster (original implementation), Hockney (rejected it as a blocker, then re-reviewed the fix), Keaton (authored the fix)
**What:** `schedule()` in `lib/scheduler.sh` is structured in three phases: (1) an **unlocked** `herdr agent list` snapshot; (2) an **unlocked** pre-fetch of P0 confirmations (`herdr pane read`) for blocked candidates that a pre-lock read of `state.json` suggests will need one, building a `confirm_cache`; (3) the state lock is acquired **only** around the actual local read-modify-write (fresh re-read of `state.json`, pruning, false-claim demotion, candidate classification, pick, save) — `confirm_cache` is consulted but every eligibility check re-validates against the freshly-locked state, never the pre-lock snapshot. A narrow in-lock fallback re-fetches `pane read` only if Phase 3's fresh state disagrees with the pre-lock snapshot (a genuine concurrent epoch-drain race). `agent focus` still runs after the lock is released.
**Why:** The original single-phase implementation held `state.lock` across `agent list` and per-candidate `pane read` calls. If those external, slow herdr calls take longer than `STATE_LOCK_STALE_SECONDS` (30s), a second concurrent yield could force-break a lock still held by a live process — a double-writer/lost-update hazard. The state lock's only job is to serialize the fast, local state.json read-modify-write (prd.md §6.7); moving all slow external I/O outside it restores the validity of the "held past 30s means the holder died" assumption without weakening the stale-lock reclaim for genuinely-dead holders. Verified via independent re-review: Phase 3 always re-reads state fresh under the lock, so no lost-update bug exists.

### 2026-08-18T22:37:23+09:00: numeric config coercion for bash arithmetic
**By:** Keaton
**What:** `lib/config.sh` added `_config_to_int`, applied to every `CONFIG_*` value that reaches bash `$(( ))` arithmetic (`aging_seconds`, `blocked_confirm_lines`, `p0_suppress_after_demotions`). A valid (optionally negative/fractional) number truncates toward zero; anything else falls back to the compiled-in default rather than crashing. `lib/state.sh`'s `STATE_LOCK_STALE_SECONDS` got the equivalent inline guard.
**Why:** Fractional `aging_seconds` (e.g. `0.5`) previously crashed bash's integer-only arithmetic under `set -euo pipefail`, silently dropping the entire yield with no user-facing signal. prd.md's config table places no integer-only constraint on `aging_seconds`, so this is a real, reachable user input, not an edge case.

### 2026-08-18T22:37:23+09:00: strict non-preemption invariant — agent focus reachable only from the two yield points
**By:** Fenster, Hockney (verified via `grep -rn "agent focus"` across the tree, both before and after the lock-scope fix)
**What:** `agent focus` is called in exactly one place in the codebase (`lib/scheduler.sh`, end of `schedule()`), reachable only via the two documented yield points: `on_status_changed.sh`'s dispatch-yield path (debounced, re-verified `-> working` transition) and `next.sh`'s explicit-yield path. All other status transitions call only `record_status` (bookkeeping) and exit — no focus-adjacent code path. v0.1's finish-focus focus redirect, `pane_is_active()`, and all viewport-diffing activity heuristics were removed outright, along with the round-based `round_done_pane_ids` model.
**Why:** prd.md §9's non-preemption invariant is the entire point of the v1 rewrite; gating all focus moves through exactly two yield points (rather than any activity-driven heuristic) is what makes the invariant provable rather than merely likely.

### 2026-08-19T21:36:10+09:00: config coercion warns to stderr; herdr captures hook stderr per invocation, readable via `herdr plugin log list` (issue #2)
**By:** Fenster (implementation), Hockney (independent verification)
**What:** `_config_to_int` in `lib/config.sh` takes an optional 3rd `<key name>` arg; on an outright-invalid value (not the accepted `-?digits(.digits)?` grammar — `"5m"`, `1e3`, a leading `+`, whitespace, empty) it emits `bashauma: config key '<key>' has invalid value "<raw>" — using default <default>` to stderr; a valid-but-fractional value still truncates silently. Live-verified against the real herdr 0.8.0-preview binary: hook stderr is not proactively surfaced on the user's screen, but it **is** captured per-invocation and retrievable via `herdr plugin log list --plugin <id>` — a real, inspectable diagnostic channel, not a warning nobody can ever read. Deliberately not rate-limited: a persistent misconfiguration keeps warning on every `schedule()` call rather than risking a user missing a one-shot notice.
**Why:** A fractional `aging_seconds` (e.g. `0.5`) previously crashed bash's integer-only arithmetic under `set -euo pipefail`, silently dropping the entire yield with no user-facing signal. A warning is only useful if there's a known path to actually read it.
**Impact:** README documents `herdr plugin log list --plugin bashauma` as the troubleshooting step for reading these warnings. Covered by `tests/cases/regression_config_warning.sh` (exact message text for all rejection variants, plus no-warning-on-valid-truncation).

### 2026-08-19T21:36:10+09:00: pane_id is not a durable identity across a herdr server restart — P0 suppression must be lineage-verified, not presence-pruned (issue #1)
**By:** Fenster (initial presence-based fix, rejected), Hockney (rejected cycle 1 with a regression test; approved-with-nits cycle 2), Keaton (shipped lineage fix)
**What:** herdr allocates `wN:pM` pane IDs from a per-workspace monotonic counter that resets on a herdr server restart, while `state.json` is a plain file that survives the restart untouched. A prune predicate keyed on "is this ID currently absent from `agent list`?" can never catch a recycled ID, because a recycled ID is by construction never observed absent before it reappears — Fenster's presence-based close-pruning (kept, for genuine unbounded-growth hygiene) closes the growth half but not the stale-suppression-on-recycle half, which the issue itself named as the more serious risk. The shipped fix instead uses `agent list`'s existing `state_change_seq` field as a monotonic lineage fingerprint: each demotion stamps `demotion_seq[pane_id]` with the seq observed at that time; inherited suppression/demotion bookkeeping (`p0_suppressed_pane_ids`/`p0_demoted_pane_ids`/`demotion_count`) is trusted only if a baseline was recorded for that pane_id AND the currently observed seq has not regressed below it — either failure wipes that pane's bookkeeping (`_forget_stale_pane`) and treats it as fresh. The design deliberately fails toward trusting/forgiving a pane rather than permanently denying it P0: wrongly distrusting a genuinely blocked pane is silent and invisible to the user, while wrongly trusting a recycled one self-corrects within a single demotion. Rejected alternatives: a restart/boot identifier (no such field exists anywhere in herdr's documented API, and the test stub has no `status` subcommand to exercise it); keying on `agent_session` (confirmed absent on at least one live pane); pure timestamp-based expiry (verifies age, not lineage, and overlaps with the separate, still-open issue #3 demotion-count-decay question). `state_change_seq` is likely a global, not per-pane, counter — Hockney found live values tightly clustered (287–314) across 6 agents in 4 workspaces vs. the clearly-per-pane `revision` field (30–60) on the same agents — which, if true, makes a restart-reset *more* certain, not less. This is unverified directly across an actual restart (neither agent disrupted Shun's live herdr session to test it), but the fix cannot regress below the pre-fix bug even if the assumption is wrong: the worst case is a silent no-op (old suppression inherited, exactly today's bug), never a new regression.
**Why:** The issue's own framing named stale-suppression-on-recycle "the more serious half"; shipping a fix that structurally cannot catch it, with a code comment asserting otherwise, would have left a real, silent, permanent-P0-denial bug on record as resolved.
**Impact:** `lib/state.sh`/`lib/scheduler.sh` gained `demotion_seq` (internal `state.json` field, not user-facing config); `herdr-plugin.toml` bumped `1.0.0` → `1.0.1`. Verbal corrected CHANGELOG.md's `1.0.1` entry (which initially described the rejected presence-based fix) and README's suppression-durability prose ("as long as the pane stays open" → "as long as that pane's identity holds") to describe the shipped mechanism; `prd.md` §6.4 judged still accurate at the spec's level of detail and left unchanged. Test suite: 16/16 passing, including `regression_id_recycle_suppression.sh` (pins the fix) and `regression_suppression_survives_lineage_check.sh` (proves the fix doesn't disable the feature it protects). Issue #3 (`demotion_count` time-decay) remains open, orthogonal, auto-triaged to Keaton.

## Governance

- All meaningful changes require team consensus
- Document architectural decisions here
- Keep history focused on work, decisions focused on direction
