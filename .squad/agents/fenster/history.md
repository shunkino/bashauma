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

## 2026-08-22T10:14:20+09:00 — Issue #4 keyword transition hold

- Implemented dispatch-only keyword transition hold with inert defaults and bottom-anchored departure-pane matching.
- Added fixed-string keyword matching (`grep -Fqi -e`) plus optional ERE `hold_pattern`, hold state bookkeeping, stderr hold logs, and explicit-`next` false-hold exemption.
- Kept `agent focus` in the existing scheduler winner path only; `next` bypasses the hold by passing `is_dispatch_yield=false` into `schedule()`.
- Added regression coverage for inert defaults, stale scrollback rejection, regex-metacharacter fixed-string matching, and `next` bypass/exemption.

📌 Team update (2026-08-22T10:14:20+09:00): Issue #4 keyword transition hold shipped as bashauma 1.2.0 with dispatch-only holds, `next` as escape hatch, documented config/logging, and 21/21 tests passing. Issue #3 demotion-count decay remains blocked until real A-0 logs show same-lineage suppression harm; #3 should reuse the lineage-check skeleton extracted for #4 — decided by Keaton, Fenster, Hockney, and Verbal.

## 2026-08-22T11:01:01+09:00 — CI pipeline fix

- Fixed ci.yml so ShellCheck and tests run independently; lint can no longer hide test failures.
- Switched CI from a bare loop over tests/cases/*.sh to ./tests/run_tests.sh with jq installed explicitly and TMPDIR set to .test-tmp.
- Made the test runner fail when zero cases are discovered or matched.
- Resolved the four SC2034 findings: removed dead test/runner variables and narrowly suppressed the harness's public C_YELLOW constant for sourced-case consumers.
- Validated 21/21 tests locally with TMPDIR=$PWD/.test-tmp, bash -n on touched shell files, YAML parsing, and ShellCheck -S warning via Docker.
