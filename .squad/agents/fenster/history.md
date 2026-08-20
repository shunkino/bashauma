# Fenster History

## Project context

- Project: herdr extension
- Primary implementation language: shell script
- Preference: lightweight automation without heavyweight frameworks
- Quality bar: normal test, lint, and review expectations
- User: Shun Kinoshita

## Core working pattern

- Keep scripts simple, readable, portable, and shell-first.
- Prefer shared helpers over duplicated scheduler logic.
- Use stderr for diagnostics that should be inspectable per invocation.
- Keep `explain` read-only with respect to real scheduling state.

## Key outcomes

- Shipped v1: state/config rewrite, scheduler, dispatch/explicit yield entrypoints, tests, and version 1.0.0.
- Shipped v1.1: `explain`, A-0 suppression logging, B-lite workspace-locality tier, and version 1.1.0.
- Fixed the A-0 explain pollution bug by gating logs to the persisted schedule path only.
- Restored `explain` report labels to the real config/state names after harness stream separation proved the rename unnecessary.
- Current rule: keep the classification cascade shared between schedule and explain; avoid drifting report-only logic.
