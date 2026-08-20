# Project Context

- **Project:** bashauma
- **Created:** 2026-08-17

## Core Context

Agent Fact Checker initialized and ready for work.

## Recent Updates

📌 Team initialized on 2026-08-17

## Learnings

Initial setup complete.

## 2026-08-19T22:29:20+09:00 — Devil's Advocate Brief: Issue #3 decay, dynamic priority (B), keyword transition hold (C)

**Requested by:** Shun Kinoshita. **Mode:** Devil's Advocate (pre-build, three parallel proposals). Verified against `prd.md` (394 lines), `lib/scheduler.sh` (568 lines), `lib/config.sh` (137 lines), `.squad/decisions.md`, and `git log`.

### Verified facts used below
- ✅ Entire scheduler + suppression mechanism is **~12 hours old**: `406e441` (v1 implementation) landed 2026-08-19 10:28, `747db7e` (the lineage/suppression fix that issue #3 is about) landed 2026-08-19 22:14 — 15 minutes before this brief was requested. The prompt's framing ("days old") is generous; the real number is hours. This *strengthens* point 5 below, it doesn't weaken it.
- ✅ prd.md §6.4 verbatim: "Determinism matters: given the same queue state, the choice must be reproducible, so the user can build intuition about where they will land." This sentence conflates two properties in one breath — reproducible and "build intuition," i.e., predictable. They are not the same property.
- ✅ prd.md §9 verbatim: "Zero unrequested context switches: focus never moves except at a yield point. This is a hard invariant, not a target."
- ✅ prd.md §6.1: dispatch (task sent) and `next` are both explicitly defined as `sched_yield()`.
- ✅ prd.md §14 verbatim: herdr's own keyword-based `blocked` detection false-positived continuously for **~15 minutes** on a working pane via a `whole_recent`-scoped scrollback match, requiring bottom-anchored confirmation + false-claim demotion to survive it in production.
- ✅ `lib/scheduler.sh`'s current pick-next is a strict lexicographic cascade over exactly 5 fields (`aged_rank, class_rank, affinity_rank, seq, pane_id`), fully sorted, with an explicit final tiebreaker (`pane_id`) added specifically so the ordering is "provably total" — this was a deliberate, reviewed design choice (Hockney's nit, per decisions.md), not an oversight. Any move to weighted/composed scoring throws this property away on purpose.
- ✅ Current suppression (`_demote_pane_to_p1`, `p0_suppress_after_demotions` default 3) has never fired in the shipped product outside test fixtures — no decisions.md entry, no CHANGELOG entry, no test failure references a real production trigger. It is a defensive mechanism for a demonstrated *class* of risk (§14's 15-minute false-blocked episode), not a reported live incident of its own.

---

### 1. Does B violate §6.4's determinism requirement in spirit?

**Yes — this is the crux, and I will not hedge it.** §6.4's own sentence structure gives away that "reproducible" and "build intuition" are meant as the same requirement, but they are formally different properties:

- **Reproducibility**: same inputs → same output, verifiable by replay. A 7-term weighted sum with floating-point coefficients is trivially reproducible.
- **Predictability**: a human, without running the algorithm, can *anticipate* the output from a mental model. This requires the ranking to be dominated by a small number of features the user actually tracks, applied in an order they can hold in their head.

A lexicographic cascade (class → affinity → aging → FIFO) is predictable *because* it is lexicographic: the user only ever needs to know "is anything blocked? no? am I about to age something out? no? then it's whoever's in this tab." Each tier is a hard gate — lower tiers never influence a decision until all higher tiers are tied. A weighted score inverts this: every signal influences every decision, all the time, by an amount the user cannot observe. Two candidates can flip rank because one's estimated time-to-unblock nudged 0.1 in a direction invisible from the terminal. That is reproducible and simultaneously the exact failure mode §9 calls "attention thrash" from the other direction — not a preempting mechanism, but a **mispredicted continuation** that breaks the "this feels like a continuation of my own intent" success metric (§9, qualitative bullet).

**What is lost if they diverge:** the entire behavioral payoff of determinism, which per §6.4's own text is that the user "can build intuition about where they will land." A system can satisfy the letter of "reproducible" while completely failing the reason that requirement is there. If Keaton ships B as a literal weighted-sum model, prd.md's own success metric becomes false by his own hand at the same time the letter of §6.4 is satisfied — that is a documentation-vs-implementation split severe enough to need its own decisions.md entry regardless of what ships.

**Steelman for B:** the counter-argument is that lexicographic cascades don't actually model "data locality" well either — a same-workspace P1 candidate that's 4 seconds old will always lose to a different-workspace P0, even when the P0 is a low-value, chatty, already-3x-demoted agent. A pure gate hides real trade-offs a human would want considered. Composed scoring can express "strongly prefer P0, but not infinitely" — which is arguably *closer* to what a human scheduler in the same seat would actually do.

**Counter-hypothesis to test before committing to any specific mechanism:** it is possible to get most of B's stated goal (workspace-locality-when-idle) by adding one more *tier* to the existing cascade rather than replacing it with weights — e.g. "when the runnable set is all-P1 and none are aged, break ties by same-workspace-as-active before FIFO." That is a 5th gate, not a re-architecture, and it stays lexicographic (hence predictable) while directly answering Shun's example ("prefer the agent in the workspace the user was already in"). This should be the first thing tried, and B's more exotic signals (estimated time-to-unblock, throughput history) should be treated as separate, individually-justified future work — not bundled into one "dynamic priority model" commit.

### 2. Is C a preemption violation in disguise?

**This deserves a precise, not hand-waved, answer: C is not literally preemption (nothing moves without a yield), but it is the same failure *family* — the plugin overriding expressed user intent — approached from the opposite direction, and prd.md's own definitions make this hard to avoid.**

Walk the invariant literally: §6.1 defines dispatch as `sched_yield()` — "I'm done here, hand me the next one" is the *user's* statement, encoded as an action (sending a task), not a suggestion. §9 states focus moves "only at a yield point," phrased as a permission (focus is *allowed* to move here) that the team has, in practice, also read as an obligation (once the debounced, re-verified dispatch fires, `agent focus` runs — decisions.md's "3-phase lock discipline" entry and the "focus reachable only from the two yield points" entry both describe an unconditional call at that point, not a conditional one). C introduces the first conditional path in the codebase: "yield happened, but don't act on it, because I saw a word in the pane." The mechanism doing the vetoing is not the user — it's a keyword match the *user configured once, in the abstract*, now being applied to a *specific, unforeseen instance* of pane text they never reviewed at the moment of the veto.

That is meaningfully different from "no preemption" but structurally identical to what §5 is defending against: a heuristic (keyword match on pane content) substituting its judgment for the user's real-time judgment about their own state. §5's ban is framed as "no focus moves without a yield"; C's failure mode is "a yield occurred and the plugin substitutes its own guess about what the user *actually* meant by it." Both are the plugin claiming better knowledge of the user's intent than the user's own explicit action. If the team accepts C, it should explicitly amend §5/§9's language to scope the invariant to "moves," not "moves or holds," rather than let this slide in as an implementation exception to a documented hard invariant.

**Steelman for C:** Shun's own example is legitimate and common: "guide me to do X" often produces a *literal* next step of "now run this command yourself" — a case where the agent's tool-call boundary and the user's actual task boundary genuinely diverge, and no yield-point mechanism can know that without inspecting content. This is a real gap the pure event-based model can't close by construction. The user is also the one authoring the bag of words, which is a meaningfully different trust posture than herdr's expert-authored, remotely-updated manifests (§14) — the user is vetoing based on rules they know they wrote, not a black box.

**The sharper question the prompt doesn't quite ask but should be flagged:** does C hold the user on the *departure* pane, or does it just skip advancing to a *specific* destination while still allowing the epoch/queue bookkeeping to proceed silently underneath? If it's the former, "who is in control" is genuinely ambiguous and worth a §9 amendment. If it's the latter (state updates as normal, only the visible `agent focus` call is withheld this one time), it's a much smaller carve-out — closer to "defer this one context switch," which is far more defensible than "override the user."

### 3. Empirical track record — realistic false-hold rate and cost asymmetry

**The asymmetry claim in the prompt is correct and should be treated as load-bearing, not just rhetorical.** §14's own measured incident is the closest available evidence: a `whole_recent`-scoped keyword scan false-positived for 15 continuous minutes on a pane that was actively working, because *earlier* output contained the trigger phrases, and it took an expert-authored manifest, refreshed and reviewed by herdr's own team, to get even that wrong. A user-authored bag-of-words config is a strictly *less* curated version of the exact same failure mode (scrollback persistence beating recency), with no equivalent of herdr's remote-manifest review process behind it.

**Cost asymmetry, made concrete:**
- A **false P0** (today's known failure mode) sends the user to a pane that isn't really asking anything. Cost: one wasted, but *visible*, context switch — the user immediately sees nothing needs their input, and (per §6.4) the false-claim demotion mechanism self-corrects within a few epochs. The failure is loud and bounded.
- A **false hold** under C is the opposite shape: the user dispatches, sees nothing happen, and has no signal that anything was *supposed* to happen. There is no "false hold demotion" analog proposed anywhere — no mechanism in the prompt's description of C self-corrects a wrong veto. The user experiences it as "the scheduler didn't respond" or, worse, doesn't notice at all and just... stays. This is silent and unbounded in a way §14's blocked false-positive was not (that one was at least visibly wrong — a blocked pane no reasonable person is stalled on).

**Realistic false-hold rate estimate:** unverifiable without building and measuring (flagged 🔍 Needs Investigation), but the base rate should be assumed *at least* as bad as §14's measured blocked false-positive rate, for the same structural reason (keyword match over pane text, no positional/recency anchoring by default) — and likely worse, because bag-of-words phrases like "run" or "shell" from Shun's own example are far more generic and far more likely to reappear anywhere in ordinary command output than herdr's specific "esc to cancel"/"enter to confirm" phrase pairs. **If C ships, it needs the same discipline §6.2 already forced onto P0 confirmation: bottom-anchored scope by default, not `whole_recent`, and ideally a demotion-equivalent self-correction (e.g., a hold that auto-expires after N seconds or after the user's next keystroke elsewhere) rather than an indefinite veto.**

### 4. Complexity budget

**Strongest case for shipping none of this:** v1 (§4) states "zero required configuration" as a *goal*, not an aspiration, and the entire rewrite's stated motivation (§2, §11) was correcting v0.1 for having "shipped both a scheduler (good) and an interrupt handler (bad)" — i.e., the last time this codebase added a heuristic beyond the core model, it had to be ripped out wholesale. A, B, and C together add: a decay/reset rule (new config surface + new state semantics for `demotion_count`), a weighted/composed scoring model (replaces a provably-total, reviewed sort with something structurally different), and a keyword engine (new config surface, new pane-read call pattern, new veto semantics layered onto the one invariant the whole PRD is built around). Each is individually defensible; together they are three new subsystems, three new places where "why did it do that" needs an answer, and three new test surfaces, landed on top of a scheduler that is *twelve hours old* and has exactly one production data point (§14) about how badly a keyword heuristic can misbehave in this exact domain.

The advocate for shipping none of this would say: the product's whole thesis is that the *lexicographic gate model itself* is the value proposition — it is simple enough to reason about, which is precisely what a CPU scheduler needs to be trusted. Every one of A/B/C trades some of that legibility for expressiveness the team has zero production evidence it needs (issue #3's suppression path has never fired; B's motivating scenario is a single hypothetical from Shun, not an observed pain point; C's motivating scenario is also a single hypothetical). Shipping zero of these and waiting for the *shipped* v1 to generate real friction reports is the load-bearing alternative, and it costs nothing except velocity on features nobody has yet needed.

### 5. Is A even a real problem?

**No evidence yet, and the timeline makes this sharper than the prompt states.** The suppression mechanism this issue is about (`_demote_pane_to_p1`'s `p0_suppress_after_demotions` threshold, plus the lineage-verification fix layered on top of it) shipped in commit `747db7e` at **22:14:48 on 2026-08-19 — roughly 15 minutes before this Devil's Advocate task was requested.** "Days old" is generous; it is *hours* old and has had essentially zero wall-clock time to accumulate a real trigger, let alone a pattern of triggers severe enough to justify a decay policy. Issue #3 itself is speculative by construction — decisions.md logs it as "orthogonal, auto-triaged to Keaton," not as a bug report against observed behavior.

**What evidence would justify building it:** a `p0_suppressed_pane_ids` entry that a user judges *wrongly* permanent — i.e., a pane that was legitimately noisy for a while, then became a genuinely well-behaved, useful P0 signal again, and the user noticed they were being denied that signal. That is cheaply collectible without writing decay logic: log (to the existing `herdr plugin log list` channel, per the config-warning precedent in decisions.md) every time a pane crosses into `p0_suppressed_pane_ids`, with pane_id and timestamp, and simply wait. If no pane accumulates a suppression entry that outlives, say, a week of real usage, decay is solving a hypothetical and should stay unbuilt. If one does, the log gives real data to size `aging`-style decay parameters against, rather than guessing.

### 6. Interaction risks — is "why did it send me here?" still answerable?

**No, not without new tooling, and this should be treated as a hard prerequisite for B specifically, not a nice-to-have.** Today, the answer to "why here?" is a fixed, ordered checklist a user can run in their head against §6.4's cascade — that answerability *is* the product, per §9's qualitative success metric. Composing B (weighted signals) with A (decaying trust, itself now time-dependent and thus non-obvious even to someone who understands the code) and C (a silent veto that may not even be visible as having fired) means three independent, opaque mechanisms can each be the true cause of an observed placement, and none of them individually explains the whole picture. Herdr already ships `agent explain` (used directly in §14's own false-positive investigation) as precedent that this class of tool is expected and used by this exact team when debugging scheduling surprises — B without an equivalent `bashauma explain <pane>` (dump the cascade/score inputs that produced the last pick) is not shippable in good conscience; it would be the first mechanism in the codebase whose behavior can't be reconstructed after the fact by the same debugging method the team already relies on.

---

### Recommendation
Do not block design work on any of A/B/C — none is unreasonable to explore — but do not let B ship as a literal weighted-sum score without: (a) an explicit prd.md amendment distinguishing reproducibility from predictability and stating which one §6.4 actually requires going forward, and (b) an `explain`-equivalent affordance landing in the *same* PR, not after. Do not let C ship with `whole_recent`-scope matching or without a time/keystroke-based self-expiring hold — reuse the §6.2 bottom-anchoring lesson explicitly, don't relearn it. Treat A as speculative until the log-and-wait evidence-gathering step above produces a real data point.

### Risk acceptance flags
- 🔺 **Accept if:** B's first shipped version is an additional lexicographic tier (not a weighted score) and ships with `bashauma explain`. **Becomes unacceptable if:** any scoring model with more than ~2 non-gated numeric signals ships without an explain affordance in the same release.
- 🔺 **Accept if:** C ships bottom-anchored by default with a bounded/self-expiring hold. **Becomes unacceptable if:** C ships scanning `whole_recent` by default, or with an indefinite veto with no auto-expiry or demotion-equivalent self-correction.
- 🔺 **Accept if:** A is deferred behind a cheap logging instrumentation step first. **Becomes unacceptable if:** decay logic ships before any real suppression event has been observed and logged from actual use.
- 🔍 **Needs investigation, not yet decided:** realistic false-hold rate for C; whether C's veto should suppress the visible `agent focus` call only, or also suspend epoch/state bookkeeping (materially changes how bad a wrong veto is).
