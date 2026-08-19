# Squad Decisions

## Active Decisions

### 2026-08-18T21:09:26+09:00: herdr extension team cast
**By:** Shun Kinoshita (via Copilot)
**What:** The project is cast as a lean, shell-first team: Keaton (Lead), Fenster (Shell Engineer), Hockney (QA / Reviewer), and Verbal (Docs / Release). Built-in Squad members are active for logging, monitoring, safety, and verification.
**Why:** This repo is intended to be lightweight, shell-driven, and publication-ready, with standard testing, review, linting, and release hygiene rather than heavy project ceremony.

### 2026-08-18T22:37:23+09:00: herdr plugins cannot ship keybindings (consolidated)
**By:** Keaton, Fenster, Verbal
**What:** `herdr-plugin.toml`'s manifest schema (`RawPluginManifestAction`) has no `[[keybindings]]` table — verified live via `herdr plugin action list` against the 0.8.0-preview binary, not assumed from prd.md. Plugins may only declare `[[actions]]` (`id`, `title`, `description`, `command`, `platforms`, `contexts`). Key binding is the **user's** responsibility, added to their own `~/.config/herdr/config.toml` via `[[keys.command]]` with `type = "plugin_action"`, `action_id = "next"` (optional `plugin_id = "bashauma"` for disambiguation). bashauma's `next` action is unreachable without this user-side step, or via `herdr plugin action invoke next` for manual testing.
**Why:** Trusting prd.md's assumption here would have baked in a wrong API shape. This is verified against the real CLI, not guessed. It's also the single most important instruction for users, since without a keybinding the `next` explicit-yield action is otherwise inaccessible.
**Impact:** README.md documents the exact `[[keys.command]]` snippet plus the `herdr plugin action invoke next` fallback; `herdr-plugin.toml` v1.0.0 ships no keybindings table.

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

## Governance

- All meaningful changes require team consensus
- Document architectural decisions here
- Keep history focused on work, decisions focused on direction
