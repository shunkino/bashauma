# PRD: bashauma (Herdr Plugin)

## 1. Summary
`bashauma` is a Herdr plugin that nudges users to keep every open agent tab moving forward. Every time the user sends a task/prompt to an agent, the plugin marks that tab as "done for this round" and automatically redirects the user's focus to the next agent tab that hasn't received a task yet. When every open agent tab has been given a task in the current round, the plugin shows a celebratory full-screen "winner" popup with 🎉/🎊 animation.

## 2. Problem
Users juggling many agent tabs tend to over-focus on one or two agents (usually the most interesting/urgent one) and let others sit idle without a new task queued, even though there's always a "next task" waiting somewhere. There's no mechanism in Herdr today that nudges a user to distribute attention/tasks across all open agents, and no positive feedback loop for actually doing so.

## 3. Goals
- After the user sends a task to an agent in one tab, automatically move focus to the next agent tab that still needs a task this round.
- Track, per "round," which open agent tabs have already received a task.
- When all currently open agent tabs have received a task in the round, show a full-screen celebratory popup ("winner screen") with a 🎉/🎊 animation, then reset for the next round.
- Handle tabs opening/closing mid-round gracefully (new tabs join the round as "not done yet"; closed tabs drop out of tracking).
- Zero required configuration for default behavior.

## 4. Non-Goals
- Not a priority/attention-sorting shortcut (that's solved by existing `agent_panel_sort = priority` / sidebar navigation).
- Does not block or prevent the user from re-focusing a tab manually — it nudges by auto-redirecting focus after a dispatch, but does not lock the UI.
- No cross-machine/remote session support.
- No persistent historical stats/leaderboard in v1 (just the per-round celebration).

## 5. Users / Use Case
A developer running many agent panes in parallel who wants a lightweight forcing function ("did I actually give everyone something to do?") plus a fun payoff for clearing the board, similar to an inbox-zero moment.

## 6. Functional Requirements

### 6.1 Core loop
1. **Detect dispatch.** Plugin listens for the signal that the user sent a task to an agent in a pane (see open question 6.4 on exact event/hook to use — likely a `pane.agent_status_changed` event hook firing when a pane transitions into `working` state, since that reflects an agent that just received and started acting on input).
2. **Mark tab done for this round.** On detecting a dispatch for pane `X`, add `X` to the round's "done" set (persisted under `HERDR_PLUGIN_STATE_DIR`).
3. **Redirect focus.** Immediately after marking `X` done, compute the set of currently open agent panes (via `agent.list`) minus the "done" set. If any remain, focus the first one (deterministic order, e.g. by workspace/tab order) via `agent.focus`, effectively pushing the user to their next task.
4. **Detect round completion.** If the "done" set now equals the full set of currently open agent panes (and is non-empty), the round is complete:
   - Open a **popup** pane (`placement = "popup"`) running a small script that renders a celebratory animation (🎉/🎊 confetti loop) using ANSI escape codes / simple frame animation in the terminal.
   - The popup closes on any keypress or after a short timer (e.g. 3–5 seconds), whichever comes first.
   - Reset the "done" set to empty, starting a fresh round.
5. **Tab lifecycle during a round:**
   - New agent pane opened mid-round → added to the "not done" pool automatically (since it's simply excluded from the "done" set); does not retroactively complete or invalidate the round.
   - Agent pane closed mid-round → removed from both the "done" set and the "currently open" set, so it no longer blocks round completion.

### 6.2 Manifest
```toml
id = "example.bashauma"
name = "bashauma"
version = "0.1.0"
min_herdr_version = "0.7.0"
description = "Forces you to give every open agent a task before celebrating a cleared board"
platforms = ["linux", "macos", "windows"]

[[events]]
on = "pane.agent_status_changed"
command = ["python3", "on_status_changed.py"]

[[panes]]
id = "winner"
title = "🎉 Winner 🎉"
platforms = ["linux", "macos"]
placement = "popup"
width = "80%"
height = "60%"
command = ["python3", "winner_screen.py"]
```

### 6.3 Implementation language
Any argv-executable language works (per Herdr's plugin model — no shell expansion, no SDK). Python recommended for straightforward JSON handling of `agent.list` output and simple terminal animation via ANSI escapes, with state tracked as a small JSON file under `HERDR_PLUGIN_STATE_DIR`.

### 6.4 Open question: exact dispatch signal
Herdr's declared plugin event hooks are driven off its internal `EventKind` set (e.g. `pane.agent_status_changed`, `pane.output_matched`, `tab.created`, `pane.created`, `worktree.created`, etc.). "User sent a task to an agent" doesn't have a single dedicated event; the closest approximate signal is a pane's `agent_status` transitioning into `working` (i.e., the agent just started acting on new input), captured via the `pane.agent_status_changed` event hook. This needs to be validated against the actual set of supported event hook names before implementation — if `working` transitions also fire for reasons unrelated to a user-sent task (e.g., agent auto-continuing on its own), the plugin may need additional filtering (e.g., comparing `state_change_seq` right after a `pane.send_text`/`pane.run` call made via this same plugin's action, rather than passively observing global state changes).

**Recommended v1 approach to avoid ambiguity:** rather than passively hooking `pane.agent_status_changed`, wrap the actual send action — i.e., provide `bashauma`'s own action/keybinding (or pane command) that the user invokes to send text to the focused agent (`pane.send_text` / `pane.run` under the hood). This guarantees the plugin knows precisely when a task was dispatched by the user, and avoids false positives from agent-internal state changes.

### 6.5 State
Stored under `HERDR_PLUGIN_STATE_DIR` as a small JSON file, e.g.:
```json
{
  "round_done_pane_ids": ["pane_abc", "pane_def"]
}
```
Read/write on every dispatch event; cleared on round completion.

## 7. API Dependencies (existing, no core changes needed)
- `agent.list` / `herdr agent list` — enumerate currently open agent panes.
- `agent.focus` / `herdr agent focus <target>` — redirect focus to the next undone tab.
- `pane.send_text` / `pane.run` — used if v1 wraps the send action directly (see 6.4).
- `plugin.pane.open` with `placement = "popup"` — render the winner screen as a modal, session-wide popup that doesn't disturb the tiled layout.
- `HERDR_PLUGIN_STATE_DIR` — persist the round's "done" set across invocations.
- `HERDR_BIN_PATH` — portable CLI invocation from the plugin process.

## 8. Winner Screen Spec
- Rendered inside a `popup` pane (session-modal, doesn't affect tab layout).
- Content: simple animated confetti/emoji loop (🎉🎊) using ANSI cursor movement and repeated frames — no external dependencies required, works in any terminal.
- Suggested size: `width = "80%"`, `height = "60%"`.
- Dismiss on any keypress (popup pane receives all terminal input while open) or auto-closes after a few seconds when the script exits.
- Optional stretch: randomize the message ("Board cleared!", "Nice work!", etc.) each time.

## 9. Success Metrics
- Qualitative: user reports feeling nudged to distribute tasks across tabs rather than tunnel-visioning on one agent.
- No regressions to normal focus/pane navigation — `agent.focus` behaves identically to manual navigation between rounds.
- Winner screen reliably triggers exactly once per completed round, with no double-fires or missed completions.

## 10. Edge Cases
- Zero agent panes open → no round tracking, no popup logic engaged.
- Only one agent pane open → "round" completes as soon as the user dispatches to it once; celebration still fires (small win still counts).
- User dispatches to the same pane twice in a row without visiting others → no redirect loop; pane is already in the "done" set, so the plugin just refocuses to the next undone pane (or does nothing if all are done and round completes).
- Popup opening returns `ui_busy` if Settings/Copy mode/another modal is active — plugin should retry shortly after or skip the celebration gracefully rather than erroring loudly.
- Pane closed exactly when round would complete → recompute the currently-open set at completion-check time (step 6.1.4) to avoid celebrating over a stale tab that no longer exists.

## 11. Rollout / Distribution
- Ship as a standalone plugin repo, installable via `herdr plugin install <owner>/<repo>[/subdir]`.
- Tag the repo with the GitHub topic `herdr-plugin` for marketplace discoverability (optional).

## 12. Open Questions
- Confirm whether to hook passively on `pane.agent_status_changed` or wrap the send action directly (6.4) — recommend the latter for v1 to avoid false positives.
- Should "done" order for redirect be workspace/tab creation order, or attention-priority order (reusing the sidebar's `blocked > done > working > idle > unknown` logic) so the "next task" nudge also respects urgency? Worth a v1.1 follow-up.
- Should there be a way to opt out of a specific tab (e.g., a long-running background agent that doesn't need a new task each round) so it doesn't block round completion forever?
