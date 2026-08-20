# Keaton History

## Project context

- Project: herdr extension
- Primary language: shell-first scripting
- Operating model: lightweight, portable automation
- Quality bar: normal testing, review, linting, and publish-readiness checks
- User: Shun Kinoshita

## Core working pattern

- Verify live CLI/schema details before changing specs or architecture.
- Prefer small, reviewable scheduler steps with explicit evidence gates.
- Keep design docs, decision logs, and shipped code aligned.

## Key outcomes

- Designed v1 after verifying the real herdr manifest/API surface and confirming there is no plugin `[[keybindings]]` table.
- Fixed review blockers: lock scope, numeric coercion, permissions hardening, and `mode=off` timing.
- Shipped the issue #1 lineage fix with `state_change_seq` / `demotion_seq` instead of presence-only pruning.
- Designed the v1.1 A/B/C proposal, then revised it after the Devil's Advocate brief to: `explain` first, then A-0 logging, then B-lite, with C hardened and A-full/B-full gated behind evidence.
- Kept the design record in sync with the persisted v1.1 scheduling document and decision inbox.
