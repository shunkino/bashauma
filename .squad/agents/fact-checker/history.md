# Fact Checker History

## Project context

- Project: bashauma
- Role: verifier and Devil's Advocate
- Focus: claim checking, counter-arguments, and evidence gating

## Core working pattern

- Challenge assumptions before design becomes implementation.
- Separate reproducibility from predictability when reviewing scheduler policy.
- Prefer empirical evidence before adding decay, scoring, or veto mechanisms.

## Key outcomes

- The Devil's Advocate brief on issue #3, B, and C established the core objections that drove the v1.1 redesign.
- Key findings: weighted scoring can be reproducible without being predictable; false holds are silent and need self-correction; A was speculative and should start with logging only; B needs an explain affordance.
- The brief explicitly pushed the team toward evidence-gated, minimal follow-up steps instead of a three-subsystem expansion.

📌 Team update (2026-08-22T10:14:20+09:00): Issue #4 keyword transition hold shipped as bashauma 1.2.0 with dispatch-only holds, `next` as escape hatch, documented config/logging, and 21/21 tests passing. Issue #3 demotion-count decay remains blocked until real A-0 logs show same-lineage suppression harm; #3 should reuse the lineage-check skeleton extracted for #4 — decided by Keaton, Fenster, Hockney, and Verbal.
