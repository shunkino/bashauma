# PRD: bashauma (Herdr Plugin)

> 馬車馬のように働く — *"to work like a carriage horse."*
> The agents are the carriage. The user is the horse.

## 1. Summary

`bashauma` is a Herdr plugin that treats **the user as the CPU** and **agents as
processes**, and applies operating-system scheduling discipline to the user's
attention.

Its one job: when the user finishes dispatching a task to an agent, decide
which agent deserves their attention next, and move focus there. Nothing else
in the plugin is allowed to move focus.

The result is a cooperative, non-preemptive scheduler for human attention:
context switches happen *only* at points the user chose, and the plugin decides
*where* they land — never *when*.

## 2. Problem

Users running many agent panes in parallel hit two failure modes:

1. **Under-utilization.** The user tunnel-visions on one interesting agent
   while others sit idle with no queued work. The parallelism they paid for
   goes unused.
2. **Attention thrash.** Every mechanism that tries to fix (1) by reacting to
   *agent* events — "this agent just finished, look at it now" — preempts the
   user mid-thought. Short tasks finish constantly, so the interrupt rate
   scales with the number of agents, and the user spends their time servicing
   interrupts instead of dispatching work. This cancels the benefit of running
   agents in parallel and is actively irritating when it fires while the user
   is typing.

The v0.1 implementation shipped both a scheduler (good) and an interrupt
handler (bad), which is what this revision corrects.

## 3. The model

| OS concept | bashauma mapping |
| --- | --- |
| CPU (single core) | The user's attention — the genuinely scarce resource |
| Process | An agent pane |
| Process is *running* | `agent_status = working` — making progress without the user |
| Process *blocked on I/O* | `agent_status = blocked` — stalled on a question/confirmation, cannot progress until the user answers |
| Process *ready to run* | `agent_status = idle` / `done` — has no work queued, needs a task |
| Context switch | `agent focus <pane>` |
| Context-switch cost | The user's mental reload: recalling the repo, the task, the conversation |
| `sched_yield()` | The user dispatching a task, or pressing the "next" key |
| Scheduler | `bashauma` picking the next pane at a yield point |
| System idle process | Nothing left to dispatch or answer → 🎉 winner screen |

The central design decision follows directly from the model: a real OS may
preempt a process because the OS can checkpoint and restore its full state. A
human's in-flight state — a half-typed prompt, a half-formed plan — **cannot be
checkpointed**. Therefore bashauma is strictly **non-preemptive**. Agent state
changes update the ready queue; they never trigger a context switch.

## 4. Goals

- Keep every open agent fed, so agent-side parallelism stays saturated.
- Move focus **only** at user-chosen yield points.
- When focus does move, land on the highest-value agent, not merely the next
  one in tab order.
- Prefer cheap context switches (same workspace/tab) over expensive ones.
- Guarantee no agent starves.
- Provide a satisfying idle state (the celebration) when the queue drains.
- Zero required configuration.

## 5. Non-Goals

- **No notifications.** bashauma never emits `herdr notification show`. Herdr
  already has good notification plugins, and a second one competing for the
  same surface is worse than none. Anything the user should be *told* about
  belongs to a notification plugin; bashauma only decides *where focus goes
  next*.
- **No preemption, of any kind, ever.** No "focus the agent that just
  finished", no timers that move focus, no interrupt-on-idle heuristics. If a
  future feature needs to move focus without the user asking, it is out of
  scope by definition.
- **No activity/typing heuristics.** v0.1 diffed pane viewports to guess
  whether the user was busy. Under a non-preemptive design that machinery is
  unnecessary and is removed.
- Not a replacement for Herdr's sidebar, `agent_panel_sort = priority`, or
  manual navigation. The user can always navigate freely; bashauma only acts at
  yield points.
- No cross-machine/remote scheduling, no historical stats or leaderboards in
  v1.

## 6. Functional Requirements

### 6.1 Yield points

Exactly two events cause bashauma to schedule:

1. **Dispatch yield** — the user sent a task to an agent. Detected via the
   `pane.agent_status_changed` event hook when a pane transitions into
   `working` (debounced and re-verified, see 6.6).
2. **Explicit yield** — the user invokes the `next` action (a manifest
   `[[actions]]` entry; the user binds a key to it in their own herdr
   config). This is `sched_yield()`: "I'm done here, give me the next one."

No other event schedules. Agent status changes that are not a dispatch update
the queue silently.

A third action, `explain`, reports what the cascade below would currently
pick and why, using the exact same classification logic as a real yield —
but it is not itself a yield point: it never calls `agent focus` and never
touches the real scheduling `state.json` or its lock (it does write a
best-effort, machine-readable sibling file, `explain.json`, purely for
introspection — `schedule()` never reads it back, so it cannot influence a
real decision). It exists to answer "why did it send me there?" without
requiring the user to simulate the algorithm from memory.

### 6.2 Ready queue and priority classes

At every yield, bashauma builds the runnable set from `agent list` and
classifies each pane:

| Class | Condition | Rationale |
| --- | --- | --- |
| *not runnable* | `agent_status = working` | Already making progress; the user adds nothing |
| *not runnable* | pane fed this epoch (see 6.3) | Already has work queued |
| **P0 — blocked** | `agent_status = blocked` | The agent is stalled on the user. Unblocking it costs the user seconds and returns an agent to `working`, so it has the highest throughput payoff per unit of user attention |
| **P1 — hungry** | `agent_status = idle` / `done`, not yet fed | Needs a new task |

Herdr's own `blocked` detection is the signal for P0: its bundled agent
manifests classify confirmation prompts and input forms (rules such as
`osc_title_plugin_confirmation_blocked`, `live_blocked_form`) as `blocked`.
This is precisely the "the agent is asking me something" signal, and it is
distinct from "the agent finished and its output could be reviewed" — the
latter is not an event bashauma reacts to at all.

**`blocked` is a candidate, not a verdict.** Empirical testing against
Copilot CLI (§14) shows the signal is real but noisy enough that acting on it
directly would send the user to agents that are not asking anything. P0
therefore requires a second, bashauma-owned confirmation:

1. Herdr reports `agent_status = blocked` for the pane, **and**
2. a `pane read --source visible` of the candidate's **bottom
   `blocked_confirm_lines` non-empty lines** matches a prompt-hint pattern
   (default: a line containing an `esc`-to-cancel hint together with an
   `enter`-to-select/confirm/submit/accept hint).

Bottom-anchoring is the entire point: herdr's Copilot rule scans a long
`whole_recent` window, so any pane that merely *mentions* those phrases
anywhere in recent scrollback is flagged. Better manifests (e.g. hermes) anchor
to `bottom_non_empty_lines(N)` for exactly this reason. A candidate that fails
confirmation is demoted to P1 for this epoch rather than discarded.

This check runs **only at a yield point, only for `blocked` candidates** — one
`pane read` per candidate. It is not polling, and it does not reintroduce
preemption.

Note that P0 quality varies per agent and can regress when herdr refreshes a
remote detection manifest, so the confirmation step is mandatory, not an
optimization. Agents whose manifests report `blocked` from an OSC title
(a source that cannot go stale the way scrollback can) may skip step 2 in a
later revision, but v1 confirms uniformly.

### 6.3 Epochs

An **epoch** is one pass over the runnable set. A pane is marked *fed* when the
user dispatches to it, and the mark clears when the epoch ends. An epoch ends
when the runnable set is empty — every open agent is either `working` or fed,
and nothing is blocked. That is the idle state, and it triggers the winner
screen (§8).

Panes that open or close mid-epoch join or leave the runnable set naturally;
closed panes are dropped from the fed set so they cannot wedge an epoch.

### 6.4 Pick-next policy

At a yield point, choose the next pane by:

1. **P0 before P1.** Answering a stalled agent returns it to `working` fastest.
2. **Affinity within a class.** Prefer a candidate in the same `tab_id`, then
   the same `workspace_id`, then the same `cwd` as the pane the user is
   leaving. Cross-workspace switches are the expensive ones — this is cache
   affinity, and it is the difference between "next task" and "next context".
3. **Aging across classes.** A P1 candidate whose wait exceeds
   `aging_seconds` is promoted above P0 so review/dispatch work cannot be
   starved by a chatty agent that keeps blocking.
4. **Workspace locality among ties.** When nothing else above has decided —
   in practice, this only ever matters among P1 candidates, since P0 or an
   aged candidate would already have won — prefer whichever candidate shares
   the departure pane's `workspace_id`. This is a fifth, purely lexicographic
   gate, not a weighted signal: it can only break a tie among candidates
   that already survived every earlier tier, so it never lets locality
   outrank class or aging.
5. **FIFO within ties**, ordered by `state_change_seq` from `agent list`
   (already exposed; no extra bookkeeping needed).
6. If the runnable set is empty → idle → winner screen and epoch reset.

**False-claim demotion.** If the user is sent to a P0 pane and leaves it
without dispatching, the P0 claim was wrong (stale prompt text, an
already-answered prompt, or a detection false positive). That pane is demoted
to P1 for the remainder of the epoch, and repeated demotions suppress its P0
eligibility entirely for as long as that pane stays open — closing the pane
clears the record. This is the multi-level-feedback-queue idea from §12
applied as a safety net: the scheduler learns to distrust a noisy signal
instead of relying on the signal being correct.

**Predictability, not mere reproducibility, is the requirement.** These are
different properties: reproducibility means identical inputs yield identical
output; predictability means the user can anticipate the result from memory,
without simulating the algorithm. A reproducible scoring function can still
be unpredictable — every signal can influence every decision by an amount
invisible from the terminal. This is why the pick-next policy above is a
lexicographic cascade of hard tiers, evaluated strictly in order, rather than
a weighted score: each tier is a gate a human can check in sequence and stop
at the first one that isn't tied, which is what actually lets them build
intuition about where they will land.

### 6.5 What happens on a status change that is not a dispatch

Nothing visible. The plugin records the pane's status for queue-building and
exits. In particular, `working → idle`, `working → done`, and
`working → blocked` **do not move focus**. They only change which class the
pane will fall into at the *next* yield.

On a dispatch yield, an optional keyword transition hold may suppress the
otherwise-normal focus move when the departure pane's bottom visible output
matches configured hold text. The dispatch still records normal bookkeeping
(including marking the departure pane fed) and logs the hold to stderr, but it
does not call `agent focus`. The explicit `next` action bypasses this hold
entirely.

### 6.6 Flicker filtering

Some agents (e.g. GitHub Copilot CLI opening/closing its "tasks" sub-view)
briefly flip detected status and back. Every dispatch detection is debounced
(~1.5s) and re-verified with `agent get` before being treated as a yield.

### 6.7 State

Under `HERDR_PLUGIN_STATE_DIR`:

```json
{
  "epoch_fed_pane_ids": ["w3:p1", "w5:p2"],
  "pane_status": { "w3:p1": "working", "w5:p2": "blocked" },
  "first_runnable_at": { "w5:p2": 1755400000 }
}
```

`first_runnable_at` is the queue-entry timestamp used for aging and FIFO
ordering. All writes are serialized with an atomic lock, since the event hook
can run concurrently for several panes.

### 6.8 Configuration

All optional; defaults require no config.

| Key | Default | Meaning |
| --- | --- | --- |
| `mode` | `on` | `on` \| `off` — `off` disables automatic dispatch scheduling but keeps the `next` action |
| `aging_seconds` | `300` | Wait after which a P1 candidate is promoted above P0 |
| `affinity` | `tab` | `tab` \| `workspace` \| `none` — how aggressively to prefer nearby panes |
| `parked_panes` | `[]` | Panes excluded from the runnable set entirely (long-running background agents) |
| `blocked_confirm_lines` | `5` | Bottom non-empty lines inspected when confirming a P0 candidate (§6.2) |
| `blocked_confirm_pattern` | built-in | Override regex for the prompt-hint confirmation |
| `blocked_confirm` | `true` | Set `false` to trust herdr's `blocked` verbatim (not recommended; see §14) |
| `hold_keywords` | `[]` | Case-insensitive fixed-string keywords that hold the user on the departure pane after a dispatch yield |
| `hold_pattern` | `""` | Optional ERE override for the dispatch-yield hold check |
| `hold_check_lines` | `15` | Bottom non-empty departure-pane lines inspected for the hold check |
| `hold_suppress_after` | `1` | False-hold overrides via immediate explicit `next` after which the pane becomes hold-exempt |

Every key also has a `BASHAUMA_<KEY>` environment override (for example,
`BASHAUMA_HOLD_KEYWORDS` as comma-separated fixed strings,
`BASHAUMA_HOLD_PATTERN`, `BASHAUMA_HOLD_CHECK_LINES`, and
`BASHAUMA_HOLD_SUPPRESS_AFTER`). The hold feature is inert until either
`hold_keywords` or `hold_pattern` is configured.

## 7. API Dependencies

All existing; no Herdr core changes required.

- `pane.agent_status_changed` event hook — dispatch detection.
- `agent list` — runnable set, plus `agent_status`, `state_change_seq`,
  `tab_id`, `workspace_id`, `cwd`, `focused` for classification and affinity.
- `agent get` — debounce re-verification.
- `agent focus` — the context switch.
- `[[actions]]` — declares the `next` and `explain` actions; key binding
  for either is user-side config, not a plugin capability.
- `plugin.pane.open` with `placement = "popup"` — winner screen.
- `HERDR_PLUGIN_STATE_DIR`, `HERDR_BIN_PATH` — state and portable CLI access.

## 8. Winner screen

- Fires when the runnable set drains: every open agent is `working` or fed, and
  none are blocked. This is the system idle state, and it is a strictly better
  win condition than v0.1's "everyone got one task", because it accounts for
  agents that came back asking questions.
- Rendered in a `popup` pane (session-modal, layout untouched), ANSI confetti,
  dismissed on any keypress or after a few seconds.
- Returns `ui_busy` if another modal is open — skip the celebration silently
  rather than erroring.
- Fires at most once per epoch.

## 9. Success Metrics

- **Utilization**: a higher fraction of open agents in `working` at any moment,
  compared to unassisted use.
- **Zero unrequested context switches**: focus never moves except at a yield
  point. This is a hard invariant, not a target. A dispatch move suppressed
  by a keyword hold is not a context switch, and no focus move ever occurs
  without a yield; the hold is strictly more conservative than v1's baseline.
- **No starvation**: no runnable pane waits longer than `aging_seconds` past
  its turn.
- **P0 precision**: a pane sent to the user as P0 is genuinely awaiting an
  answer. Measured by the false-claim demotion rate (§6.4) — a rising rate
  means the confirmation heuristic needs tuning.
- Qualitative: the user reports that landing somewhere after dispatch feels
  like a continuation of their own intent, not an interruption of it.

## 10. Edge cases

- **Zero or one agent open** — scheduling is a no-op; a single agent still
  completes an epoch and still celebrates.
- **All agents blocked** — every pane is P0; the queue is fully runnable and
  drains as the user answers. No deadlock is possible because the user is
  always the one holding the lock.
- **User dispatches to the same pane twice** — it is already fed; the scheduler
  simply picks the next runnable pane.
- **An agent that never needs tasks** (long-running watcher) — `parked_panes`
  keeps it out of the runnable set so it cannot hold an epoch open.
- **Herdr unreachable / `agent list` fails** — leave all state untouched and do
  nothing. Never guess.

## 11. Rollout

- Ship as a standalone plugin repo, installable via
  `herdr plugin install <owner>/<repo>`.
- Tag the repo with the `herdr-plugin` GitHub topic for marketplace discovery.
- Migration from v0.1: the finish-focus behavior and its viewport-diffing
  activity detection are removed outright. Users who liked being pulled to
  finished agents should install a notification plugin instead — that is the
  correct surface for it.

## 12. Future directions (OS principles not yet applied)

These are deliberately deferred, but the model makes each of them a small,
natural extension rather than a new feature bolted on:

- **Multi-level feedback queue.** Track how much user time each agent consumes.
  Agents that repeatedly block on trivial questions get demoted (they are
  attention hogs); agents that run long stretches autonomously get promoted
  (they are cheap and high-yield). Periodic priority boost prevents permanent
  demotion.
- **Shortest-job-first for human time.** Estimate the user-time cost of each
  pending interaction with an exponential moving average of past interactions
  (`τₙ₊₁ = α·tₙ + (1−α)·τₙ`) and schedule cheap answers first. SJF minimizes
  mean waiting time, which here means agents spend less wall-clock time stalled
  on the user.
- **`nice` values and pinning.** Let the user bias the scheduler per pane
  (`bashauma nice -5 w3:p2`), or pin themselves to one workspace for a stretch
  (an affinity mask) when doing focused work.
- **Admission control and thrash detection.** There is a degree of
  multiprogramming beyond which the user's context-switch overhead exceeds the
  throughput gained. Track mean queue wait and switch rate; when the system is
  thrashing, tell the user they are running too many agents — the human
  equivalent of a load average — and suggest parking some.
- **Swapping.** Automatically park agents that have gone untouched for a long
  time, and bring them back when the queue is quiet.
- **Working-set restore.** On a context switch, surface the last question or
  last few lines from the destination pane, so the user's mental cache is
  warmed by the scheduler rather than by scrolling. This directly attacks
  context-switch cost, which is the dominant term in the whole model.
- **Gang scheduling.** Panes working on one feature across several repos are
  visited as a group, so related context is loaded once.

## 13. Open questions

- ~~Does `blocked` fire reliably for Copilot CLI?~~ **Resolved by measurement —
  see §14.** It fires for real prompts, but also false-positives badly, hence
  the confirmation step in §6.2.
- How long does a stale prompt hint linger in Copilot's `whole_recent` window
  after the user answers? Bottom-line confirmation makes this mostly moot, but
  it sets how aggressive false-claim demotion needs to be.
- Should the `next` action also be offered as "next, but skip this class"
  (jump straight to hungry panes, ignoring blocked ones) for users who want to
  batch dispatch work separately from answering questions?
- Should an epoch boundary be visible at all when the user is mid-flow, or
  should the celebration be suppressible (`mode = quiet`) for users who want
  the scheduling without the confetti?

## 14. Appendix: measurement of the `blocked` signal

Measured 2026-08-18 against herdr protocol 19, Copilot CLI 1.0.18, detection
manifest `copilot.toml` version `2026.07.07.1`, on a live session of five
Copilot agent panes.

**Copilot state detection is entirely screen-scraped.** Herdr's Copilot
integration hook reports only the agent *session id*
(`pane.report_agent_session`) and exits for every non-`SessionStart` event, so
no authoritative state ever reaches herdr. All state comes from one rule:

```toml
[[rules]]
id = "selection_blocker"
state = "blocked"
priority = 300
region = "whole_recent"
all = [
  { any = [ {contains = ["esc to cancel"]}, {contains = ["esc cancel"]} ] },
  { any = [ {contains = ["enter to select"]}, {contains = ["enter to confirm"]},
            {contains = ["enter to submit"]}, {contains = ["enter accept"]} ] },
]
```

**True positive: confirmed.** A live selection prompt renders

```
│ ↑/↓ to select · enter to confirm · esc to cancel │
```

which satisfies both clauses. Real prompts do produce `blocked`, so P0 has a
usable basis.

**False positive: confirmed, severe, sticky.** Because the region is
`whole_recent` rather than the prompt area, a pane that merely *displays* those
phrases anywhere in recent scrollback is flagged. During the test, the pane
running this very analysis was reported `blocked` continuously for roughly
15 minutes while actively working, because earlier command output contained the
phrases. `herdr agent explain` attributed it to `selection_blocker` with
evidence spanning long-stale output. Since blocked (priority 300) outranks
`working_cancel_hint` (priority 100), the false positive *overrides* the
correct working state.

**`revision` is not a usable disambiguator.** The hoped-for "is output still
moving?" check fails: `revision` stayed pinned at 17 across a busy stretch of
the same pane, so a stalled and a working pane are indistinguishable by it.

**Conclusions carried into the design:** P0 requires bottom-anchored
confirmation (§6.2); false P0 claims must be self-correcting via demotion
(§6.4); and the plugin must never assume a detection manifest is precise,
because manifests are refreshed remotely and their quality varies per agent.
