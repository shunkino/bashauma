# Project Context

- **Project:** bashauma
- **Created:** 2026-08-17

## Core Context

Agent Rai initialized and ready for work.

## Recent Updates

📌 Team initialized on 2026-08-17
📌 2026-08-18 — Reviewed bashauma v1 (state.sh, config.sh, scheduler.sh, on_status_changed.sh, next.sh, herdr-plugin.toml, winner_screen.sh, README, tests). Verdict: 🟡 Yellow, no 🔴. Full findings in `.squad/rai/audit-trail.md`.

## Learnings

Initial setup complete.

- **Pane-content handling in bashauma is clean by design.** `confirm_p0()` in lib/scheduler.sh reads `herdr pane read --source visible` into a shell var but only ever pipes it through `awk`/`grep -Eq` for a boolean match; it is never written to state.json, logged, or echoed. state.json's schema (pane_id/status/timestamps/counters only, no cwd, no pane text) is a good minimal-persistence pattern worth citing as a positive example in future reviews of similar herdr plugins.
- **User-configurable regex passed to `grep -E` without `-e`/`--` is a recurring low-severity injection-adjacent pattern.** A leading `-` in a config-supplied pattern gets parsed as a grep option instead of a literal pattern (verified: `grep -Eq '-e'` → "option requires an argument"). Watch for this any time a plugin exposes a user-configurable regex/string that gets interpolated as a bare (non `-e`/`--`-guarded) argument to grep/sed/awk.
- **Doc/code drift on privacy-relevant behavior is a distinct finding category from actual code bugs.** bashauma's README described a "finish-focus" + pane-viewport-diffing activity check that prd.md explicitly says was removed in v1 and that does not exist in the shipped code — worth flagging as advisory (ungrounded-claim-adjacent) even when the actual code turns out to be the *safer* of the two, because users can't audit privacy behavior correctly from docs that don't match the code.

📌 Team update (2026-08-18T22:37:23+09:00): automatic RAI pass on bashauma v1 verdict Yellow (no persisted pane content, no blockers); both advisories (grep option-injection, file permissions) fixed by Keaton same session — decided by Rai.
