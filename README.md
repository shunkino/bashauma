# bashauma 🐴

> 馬車馬のように働く — *"to work like a carriage horse."*
> The agents are the carriage. The user is the horse.

`bashauma` is a [Herdr](https://herdr.dev) plugin that treats **you** as the
CPU and your agent panes as processes, and applies ordinary OS scheduling
discipline to the one resource that can't be virtualized: your attention.

Its one job: when you finish dispatching a task to an agent, decide which
agent deserves your attention next, and move focus there. Nothing else in the
plugin is allowed to move focus — not a finished task, not an idle timer, not
a hunch that you look distracted. Focus moves only at points you chose, and
`bashauma` decides only *where* they land, never *when*.

That makes it a cooperative, non-preemptive scheduler for human attention. A
real OS can preempt a process because it can checkpoint and restore full
process state. It cannot checkpoint your half-typed prompt or half-formed
plan. So `bashauma` doesn't try — it waits for you to yield, on purpose, and
then picks well. See [`prd.md`](./prd.md) for the full spec this README is
built from.

## The model

| OS concept | bashauma mapping |
| --- | --- |
| CPU (single core) | Your attention — the scarce resource |
| Process | An agent pane |
| Running | `agent_status = working` — making progress without you |
| Blocked on I/O | `agent_status = blocked` — stalled on a question or confirmation |
| Ready to run | `agent_status = idle` / `done` — has no work queued |
| Context switch | `agent focus <pane>` |
| Context-switch cost | Reloading the repo, the task, the conversation in your head |
| `sched_yield()` | You dispatching a task, or pressing your bound "next" key |
| Scheduler | `bashauma` picking the next pane at that yield point |
| System idle | Nothing left to dispatch or answer → 🎉 winner screen |

## What it deliberately does not do

This is the design thesis, not a missing-features list:

- **No notifications.** `bashauma` never calls `herdr notification show`.
  Herdr already has plugins for that job; a second one competing for the same
  surface is worse than none. If you want to be *told* something, that's a
  notification plugin's job — `bashauma` only decides where focus goes next.
- **No preemption, ever.** No "focus the agent that just finished," no timers
  that move focus, no interrupt-on-idle heuristics. An agent finishing its
  work does not, by itself, move your cursor anywhere. A keyword hold can
  only suppress a dispatch-yield move; it never creates a new way to move
  focus.
- **No activity or typing heuristics.** Nothing diffs your pane's viewport to
  guess whether you're "busy." Under a non-preemptive design that machinery
  has no job to do.

If a future feature would need to move focus without you asking for it, it's
out of scope by definition.

## Requirements

- [Herdr](https://herdr.dev) **0.8.0 or newer**
- `bash` and [`jq`](https://jqlang.github.io/jq/) on your `PATH`
- macOS or Linux

```sh
# macOS
brew install jq
# Debian / Ubuntu
sudo apt install jq
```

## Install

```sh
herdr plugin install shunkino/bashauma
herdr plugin enable bashauma
```

Verify it's loaded:

```sh
herdr plugin list
```

## Bind a key to `next` — do this first

Half of `bashauma` is invisible without this step. The plugin ships two
scheduling entry points, but **only one of them can be triggered automatically**:

1. **Dispatch yield** — fires on its own whenever a pane transitions into
   `working`. You don't need to do anything for this one.
2. **Explicit yield (`next`)** — "I'm done here, give me the next runnable
   pane." This is how you yield when you're *not* dispatching a task: you
   finished reading a diff, answered a question, or just want to move on.

Herdr plugin manifests have no `[[keybindings]]` table — plugins cannot ship
key bindings for their own actions. You have to bind `next` (and, if you want
it, `explain` — see below) yourself, in your own `~/.config/herdr/config.toml`:

```toml
[[keys.command]]
key = "prefix+n"
type = "plugin_action"
action_id = "next"

[[keys.command]]
key = "prefix+shift+n"
type = "plugin_action"
action_id = "explain"
```

(Add `plugin_id = "bashauma"` to either block if you have another plugin with
a conflicting action id.) Pick whatever keys suit your muscle memory —
these are just suggestions.

To test either action without binding a key at all:

```sh
herdr plugin action invoke next
herdr plugin action invoke explain
```

## Yield points, in full

Exactly two events cause `bashauma` to schedule. Every other status change —
`working → idle`, `working → done`, `working → blocked`, or anything in
between — updates its bookkeeping silently and **does not move focus**. That
silence is the hard invariant the whole design rests on: the only two ways
your focus ever moves are the dispatch yield and your own `next` key.

Dispatch detection is debounced (~1.5s, `BASHAUMA_DEBOUNCE_SECONDS`) and
re-verified with `agent get` before being trusted, to filter out agents (e.g.
Copilot CLI opening/closing its "tasks" sub-view) that briefly flip status
and flip back with no real dispatch behind it.

A third action, `explain`, is **not** a yield point — invoking it never moves
focus and never touches the real scheduling state. See "Why did it send me
*there*?" below.

## How the next pane is picked

At a yield, `bashauma` builds the runnable set from `agent list` — every open
pane that isn't already `working` and hasn't been fed this epoch — and ranks
it:

1. **P0 (blocked) before P1 (hungry).** A `blocked` pane is stalled waiting on
   you; answering it costs seconds and returns an agent to `working`, which is
   the highest throughput you can buy per second of your attention. An `idle`
   or `done` pane just needs a new task, which is real but lower-urgency work.
2. **Affinity within a class.** Prefer a candidate in the same tab, then the
   same workspace, then the same working directory as the pane you're
   leaving — cheap context switches over expensive ones.
3. **Aging across classes.** A P1 candidate that's waited past `aging_seconds`
   jumps ahead of P0, so a chatty agent that keeps triggering blocked prompts
   can't starve everything else.
4. **Workspace locality among ties.** If everything above is still tied — in
   practice this only ever matters among untied P1 candidates, since P0 or
   an aged candidate has already won by this point — prefer whichever
   candidate shares the workspace you're leaving from. This is a hard gate,
   not a weighted score: it can only ever break a tie among candidates that
   already survived every earlier rule, so it can never let locality beat
   class or aging.
5. **FIFO within ties**, by `state_change_seq` — deterministic, so you can
   build intuition about where you'll land.
6. Nothing runnable → the epoch has drained → 🎉 winner screen, and the epoch
   resets.

Every one of those is a hard gate evaluated strictly in order — never a
weighted score. That's deliberate: a score that blends several signals into
one number is just as reproducible as a cascade (the same inputs always
produce the same output), but it isn't *predictable* — you'd have to run the
math to know where you'll land, which defeats the entire point of "next" being
something you can trust without thinking about. A cascade lets you check one
rule at a time and stop at the first one that isn't tied.

**"Blocked" is a candidate, not a verdict.** Herdr's own `blocked` detection
can be noisy per agent (see [`prd.md` §14](./prd.md#14-appendix-measurement-of-the-blocked-signal)
for the measurement that justifies this — short version: Copilot CLI's
`blocked` signal false-positives badly on stale scrollback). So before a
`blocked` pane is trusted as P0, `bashauma` re-reads the bottom
`blocked_confirm_lines` non-empty lines of its viewport and checks them
against a prompt-hint pattern itself. If a pane fails that check, it's
demoted to P1 for the epoch. If you get sent to a P0 pane and leave without
dispatching, the same thing happens — the claim was wrong, so the pane drops
to P1, and `p0_suppress_after_demotions` demotions (default `3`) disqualify
it from P0 for as long as that pane's *identity* holds. Suppression is
verified, not just remembered by `pane_id`: each demotion stamps the
`agent list` sequence number (`state_change_seq`) seen at the time, and a
pane only inherits its own suppression history if that number hasn't gone
backwards since. A closed pane's record is dropped outright, and — the
harder case — if a herdr restart ever recycles a `pane_id` onto a brand-new
agent, that agent's sequence number won't match what was recorded for its
predecessor, so it starts with a clean slate instead of inheriting a
stranger's distrust. In practice this means: a pane that keeps falsely
claiming P0 stays suppressed for as long as it's genuinely the same live
agent, but you're never permanently and silently denied P0 by an agent
that merely reused an old pane's ID.

## Staying put after a dispatch (`hold_keywords`)

Some agents print a prompt that means "don't leave yet" right as they enter
`working` — for example, a command confirmation. `bashauma` can be told to
hold that dispatch yield, but only if you opt in by setting `hold_keywords`
(or the power-user `hold_pattern`). With the default empty keyword list and
empty pattern, this feature is inert and spends no extra departure-pane read.

On a dispatch yield only, `bashauma` reads the departure pane's bottom
`hold_check_lines` non-empty visible lines. If a `hold_keywords` entry matches
there, the match is case-insensitive and fixed-string: regex punctuation in a
keyword is literal. If `hold_pattern` is set, it is checked as an ERE override.
A match does the most conservative thing possible: it records the dispatch,
keeps you where you are, makes no `agent focus` call at all, and logs:

```text
bashauma: held pane <pane_id> on dispatch yield (matched <keyword|pattern>: "<value>")
```

The hold never applies to `next`. Pressing your bound `next` key immediately
after a hold is the escape hatch and counts as a false-hold override for that
pane; at the default `hold_suppress_after = 1`, the pane becomes hold-exempt
for the same live pane lineage.

## Why did it send me *there*? (`explain`)

`next` and dispatch are silent by design (that's the whole point of not
narrating every decision), but silence has a cost: sometimes you land
somewhere and can't tell why. `explain` answers exactly that, without
guessing and without moving anything:

```sh
herdr plugin action invoke explain
```

It runs the same classification the real scheduler would use for your
current pane — the identical code path, not a second copy that could drift
out of sync — and prints every runnable candidate ranked by the real cascade
(aged, class, affinity, workspace locality, sequence, pane ID), with the
would-be winner marked. For each candidate you get its class (P0/P1), whether
it's aged, its affinity and workspace-locality rank, its raw
`state_change_seq`, and its suppression/demotion state. It never calls
`agent focus` and never touches the real `state.json` or its lock, so it
can't move you or affect a later real decision — you can run it as many
times as you want, mid-thought, with zero effect on the actual queue. (It
does write a best-effort `explain.json` next to the real state file, purely
so the same report is available machine-readably; `schedule()` never reads
that file back, so it has no way to feed into a real decision.) It's the
answer to "why did it send me *there*?", and arguably the most useful single
command in this plugin.

## Configuration

All optional — the defaults require zero configuration. Config is **JSON**,
not TOML, at `$HERDR_PLUGIN_CONFIG_DIR/config.json`. This is a deliberate
deviation from a TOML-everywhere assumption: `jq` is already a hard
dependency for state and CLI-output parsing, so a second, ad hoc TOML parser
for a handful of scalar knobs isn't worth adding.

| Key | Default | Meaning |
| --- | --- | --- |
| `mode` | `"on"` | `"on"` \| `"off"` — `"off"` disables *automatic* (dispatch-triggered) scheduling; the `next` action keeps working either way. |
| `aging_seconds` | `300` | Wait after which a P1 candidate is promoted above P0. |
| `affinity` | `"tab"` | `"tab"` \| `"workspace"` \| `"none"` — how aggressively to prefer nearby panes. |
| `parked_panes` | `[]` | Pane IDs excluded from the runnable set entirely (e.g. long-running background watchers). |
| `blocked_confirm_lines` | `5` | Bottom non-empty lines inspected when confirming a P0 candidate. |
| `blocked_confirm_pattern` | built-in `esc`/`enter` prompt-hint regex | Override regex for the prompt-hint confirmation. |
| `blocked_confirm` | `true` | Set `false` to trust herdr's `blocked` verbatim (not recommended — see the §14 note above). |
| `p0_suppress_after_demotions` | `3` | How many times a pane can falsely claim P0 before the scheduler stops trusting its `blocked` signal — for as long as it's provably the same live pane (see above). |
| `hold_keywords` | `[]` | Case-insensitive fixed-string keywords that hold you on the departure pane after a dispatch yield. Empty by default, so the feature is inert until you opt in. |
| `hold_pattern` | `""` | Optional ERE override for the dispatch-yield hold check. |
| `hold_check_lines` | `15` | Bottom non-empty departure-pane lines inspected for the hold check. |
| `hold_suppress_after` | `1` | Immediate `next` overrides after which the same live pane becomes hold-exempt. |

Example `config.json`:

```json
{
  "aging_seconds": 120,
  "affinity": "workspace",
  "parked_panes": ["w1:p9"]
}
```

Every key above also has a `BASHAUMA_<KEY>` environment override, useful for
one-off tuning without touching the config file:

| Env var | Overrides |
| --- | --- |
| `BASHAUMA_MODE` | `mode` |
| `BASHAUMA_AGING_SECONDS` | `aging_seconds` |
| `BASHAUMA_AFFINITY` | `affinity` |
| `BASHAUMA_PARKED_PANES` | `parked_panes` (comma-separated pane IDs) |
| `BASHAUMA_BLOCKED_CONFIRM_LINES` | `blocked_confirm_lines` |
| `BASHAUMA_BLOCKED_CONFIRM_PATTERN` | `blocked_confirm_pattern` |
| `BASHAUMA_BLOCKED_CONFIRM` | `blocked_confirm` |
| `BASHAUMA_P0_SUPPRESS_AFTER_DEMOTIONS` | `p0_suppress_after_demotions` |
| `BASHAUMA_HOLD_KEYWORDS` | `hold_keywords` (comma-separated keywords) |
| `BASHAUMA_HOLD_PATTERN` | `hold_pattern` |
| `BASHAUMA_HOLD_CHECK_LINES` | `hold_check_lines` |
| `BASHAUMA_HOLD_SUPPRESS_AFTER` | `hold_suppress_after` |

`aging_seconds`, `blocked_confirm_lines`, `p0_suppress_after_demotions`,
`hold_check_lines`, and `hold_suppress_after` are the numeric knobs the
scheduler does integer arithmetic with. Each
is coerced rather than trusted verbatim, and the two failure modes are
treated differently:

- A **valid but fractional** number truncates toward zero silently — no
  warning, this is expected, documented behavior (`"30.9"` → `30`,
  `"-2.9"` → `-2`).
- An **outright invalid** value (non-numeric garbage like `"5m"`, scientific
  notation like `1e3`, a leading `+`, surrounding whitespace, empty, or
  `null`) falls back to that key's own compiled-in default **and emits a
  one-line warning to stderr**, e.g.:

  ```
  bashauma: config key 'aging_seconds' has invalid value "5m" — using default 300
  ```

A typo therefore never crashes the scheduler — it quietly behaves as if you
hadn't set it — but it isn't silent either. See Troubleshooting below for
where that stderr output actually goes.

Two knobs live outside `config.json` because they're plugin-internal timing,
not scheduling policy, and pre-date the config file:

| Env var | Default | What it does |
| --- | --- | --- |
| `BASHAUMA_DEBOUNCE_SECONDS` | `1.5` | How long to wait and re-verify before trusting a `working` transition as a real dispatch. |
| `BASHAUMA_LOCK_STALE_SECONDS` | `30` | How long to wait on the state lock before assuming a previous run died and breaking it. |

**One behavior worth calling out explicitly:** `mode = "off"` only disables
the dispatch-yield path (`on_status_changed.sh`). It does not disable the
`next` action — pressing your bound key still reschedules and moves focus.
"Off" means "don't yank me around automatically," not "stop working."

### State storage

State lives at `$HERDR_PLUGIN_STATE_DIR/state.json`. The state directory and
its lock directory are created `chmod 700`, and `state.json` itself is
written `chmod 600` — the file only holds pane IDs and internal scheduling
bookkeeping (no secrets), but it's owner-only regardless.

Running `explain` (see above) additionally writes a sibling file,
`explain.json`, in the same directory with the same permissions — a
best-effort, machine-readable copy of its report. It's diagnostic only:
`schedule()` never reads it, so it can't affect a real decision.

## Migrating from v0.1

v1 removes v0.1's "finish-focus" behavior and its viewport-diffing activity
detection **outright** — they are not configurable off, they're gone. In
v0.1, an agent finishing (`working → idle/done/blocked`) would pull your
focus to it unless you looked busy; in v1, that transition only updates the
scheduler's bookkeeping and never touches focus. If you liked being pulled to
a finished agent, that's a job for a notification plugin now, not a
scheduler — install one alongside `bashauma` instead.

Along with that removal, `BASHAUMA_ACTIVITY_CHECK_SECONDS` (the viewport-diff
polling window) is gone; there is no replacement, because there's no more
activity detection to configure. `BASHAUMA_DEBOUNCE_SECONDS` and
`BASHAUMA_LOCK_STALE_SECONDS` are unchanged from v0.1.

## Development

Run the test suite from the repo root:

```sh
tests/run_tests.sh                 # every case
tests/run_tests.sh 6_1 6_5         # only cases matching a filename fragment
```

It's a dependency-free `bash` + `jq` suite (no test framework) with a fake
`herdr` CLI stub — see [`tests/README.md`](./tests/README.md) for how to
script it and add new cases. Passing green is a reasonable release gate.

## Troubleshooting

- **My config isn't taking effect, or did a hold fire?** A config value
  that's outright invalid (not just fractional) is rejected and replaced
  with its default, and logs a one-line warning. Keyword holds also log
  their exact matched keyword or pattern. Plugin-script stderr isn't
  printed to your terminal, so read it with:

  ```sh
  herdr plugin log list --plugin bashauma
  ```

  Each entry carries its own stderr, so this is also the answer to "did my
  `next` press actually do anything?" in general — check here first.
- **Nothing happens on dispatch.** Confirm the plugin is enabled
  (`herdr plugin list`) and that `jq` is installed — the hook exits silently
  without it. Check `herdr plugin log list` for what actually ran.
- **`next` does nothing.** Confirm you've bound a key (see above), or test the
  action directly with `herdr plugin action invoke next`.
- **I don't understand why I landed on this pane.** Run
  `herdr plugin action invoke explain` — it reports the full ranked
  candidate list for the pane you're on, using the same logic the real
  scheduler used, with no side effects.
- **Focus never moves.** `bashauma` only tracks panes `herdr agent list`
  reports as agents; plain shell panes are ignored.
- **The winner screen won't fire.** It fires at most once per epoch, and only
  when at least one pane is open. If herdr reports another modal is already
  open, it skips silently rather than erroring — check `herdr plugin log
  list`.
- **State looks stuck.** Wipe it:

  ```sh
  rm -rf "$HERDR_PLUGIN_STATE_DIR"/state.json "$HERDR_PLUGIN_STATE_DIR"/state.lock
  ```
