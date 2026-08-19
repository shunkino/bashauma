# RAI Audit Trail

> Append-only evidence log. Entries are redacted — never contains raw secrets or harmful content.

<!-- Rai appends findings below -->

## 2026-08-18 — bashauma v1 RAI review (lib/state.sh, lib/config.sh, lib/scheduler.sh, on_status_changed.sh, next.sh, herdr-plugin.toml, winner_screen.sh, README.md, tests/)

**Verdict: 🟡 Yellow** (no 🔴 Critical findings; advisory only, work proceeds)

Reviewer: Rai. Scope: highest-risk surface (`herdr pane read --source visible` handling), injection, PII/privacy, file permissions, content, dark patterns.

### 🟢 Clean — pane content handling (highest-risk surface)
- `confirm_p0()` (lib/scheduler.sh:66-70) reads pane text into a local shell var, pipes it only through `awk`/`tail`/`grep -Eq`; the matched result is a boolean exit code. Pane content is never written to `state.json`, never logged, never echoed to stdout/stderr in the plugin code paths. `state.json` schema stores only `pane_id`, `agent_status`, timestamps, and demotion counters — no `cwd`, no pane text. `cwd`/`tab_id`/`workspace_id` are read into memory for affinity ranking (lib/scheduler.sh `_affinity_rank`) but never persisted. Test fixtures (`tests/fixtures/bin/herdr`, `tests/cases/*.sh`) contain only synthetic placeholder text, no real-looking secrets.

### 🟡 Finding 1 — grep option-injection via user-configurable `blocked_confirm_pattern`
- **WHAT:** lib/scheduler.sh:70 — `grep -Eq "$CONFIG_BLOCKED_CONFIRM_PATTERN"`. If a user (or a shared/templated config file) sets this to a string starting with `-` (e.g. `-f/etc/hostname`, `--foo`), grep parses it as an option, not a pattern.
- **WHY:** Not remote-exploitable (config is local/self-authored), but it's a config-input-into-shell-command path with no defensive quoting against leading-dash args — the exact shape of an injection primitive, and it silently changes matching behavior (fails to P1 misclassification at best, on GNU grep `-f<file>` could read an arbitrary local file's lines as patterns).
- **HOW:** Change to `grep -Eqe "$CONFIG_BLOCKED_CONFIRM_PATTERN"` (or `grep -E -- "$PATTERN"`) so a leading `-` can never be parsed as an option, on both GNU and BSD/macOS grep. Malformed regex (unbalanced parens etc.) was verified to fail safely today (`grep` exits 2 → treated as `false` → pane demotes to P1, no crash, no false P0) — that part needs no change.

### 🟡 Finding 2 — no explicit file permissions on state/lock files
- **WHAT:** `state_save()` (lib/state.sh:78) and `state_acquire_lock()` write `state.json` / create `state.lock` with no `chmod`/`umask` hardening; `HERDR_PLUGIN_STATE_DIR` defaults to `$TMPDIR`/`/tmp`, a shared, often world-writable directory.
- **WHY:** State content itself is low-sensitivity (pane ids, statuses, timestamps), so this is not a secrets leak, but on a shared multi-user machine another local user could read pane IDs/status/timing metadata, and the predictable `$STATE_FILE.tmp.$$` name in a shared tmp dir is a minor hygiene gap.
- **HOW:** `chmod 600` the state file after `state_save`'s `mv`, and consider `mkdir -m 700` semantics is already implicit for the lock dir via `mkdir` — just add an explicit `chmod 700 "$STATE_DIR"` once at first creation. Low priority.

### 🟡 Finding 3 — README describes a feature the v1 code intentionally does not have
- **WHAT:** README.md's "Quickstart" step 5 preamble and "How it works" section describe a "finish-focus" behavior (auto-focus on agent completion) and "activity detection via diffing `pane read --source visible` snapshots," plus document `BASHAUMA_ACTIVITY_CHECK_SECONDS` as an active knob. None of this exists in the shipped code: `on_status_changed.sh` only calls `record_status` for any transition out of `working` and explicitly never calls focus for it (matching prd.md §6.5's hard invariant and §11's migration note that "the finish-focus behavior and its viewport-diffing activity detection are removed outright" in v1). `grep` confirms `ACTIVITY`/`activity` do not appear anywhere in `lib/*.sh`, `on_status_changed.sh`, or `next.sh`.
- **WHY:** This is a Deceptive-Content-adjacent ungrounded claim about the software's actual behavior in user-facing docs — a user relying on the README to understand *when their screen gets read/diffed* would form an inaccurate privacy picture (in this case the actual behavior is safer than documented, but the direction of the drift matters less than the fact that docs and code disagree on a privacy-relevant behavior).
- **HOW:** Update README.md's "How it works" and Quickstart to match the actual v1 behavior (no finish-focus, no activity diffing — only the two documented yield points), and drop the `BASHAUMA_ACTIVITY_CHECK_SECONDS` row from the Knobs table since it's dead config referenced nowhere in the sourced code. Recommend routing to Fenster (implementation) or Scribe (docs owner) for the README fix.

### 🟢 Content review
- `winner_screen.sh` messages, README framing ("middle management," "the horse does not get options," 馬車馬 metaphor), and manifest descriptions: no exclusionary, harmful, or ableist/gendered terminology found (scanned against the terminology-standards table in `.squad/rai/policy.md`). Per task instructions, no ethical commentary is offered on the 馬車馬 metaphor itself — it is the author's own framing of their own workflow.
- No dark-pattern/manipulation finding beyond the intentionally comedic framing the author explicitly owns; the scheduling logic yields deterministically per prd.md's documented rules with no hidden nudging, no engagement-maximizing tricks, and a genuine "no automatic scheduling" escape hatch (`mode = off`) that stays fully honored.

### Remediation status
All three 🟡 findings are advisory (non-blocking). No fix agent lockout triggered. Suggested owner: Fenster (Shell Engineer) for Findings 1–2 (lib/scheduler.sh, lib/state.sh); Fenster or Scribe for Finding 3 (README.md).
