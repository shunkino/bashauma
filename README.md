# bashauma 🐴

> 馬車馬のように働く — *"to work like a carriage horse"*: head down, blinders on,
> never stopping.

Your AI agents are the carriage. **You** are the horse.

`bashauma` is a [Herdr](https://herdr.dev) plugin that removes the last
bottleneck in your AI-powered workflow: the human who keeps getting distracted
by one interesting agent while five others sit idle, quietly billing you
nothing and producing exactly as much.

The moment you dispatch a task, `bashauma` yanks your focus to the next agent
that hasn't been fed. Dispatch again. Next. Again. Next. When an agent finishes
and needs you, it drags you back there too. There is no "just let me read this
diff for a second." There is only the next pane.

Feed every open agent in a single round and you get a full-screen 🎉 confetti
celebration — roughly three seconds of joy — before the next round begins.

You wanted AI to do the work. Congratulations: you are now middle management,
and management never rests.

See [`prd.md`](./prd.md) for the full (straight-faced) product spec.

## Demo

<p align="center">
  <img src="https://placehold.co/960x540/1f2937/ffffff?text=Bashauma+demo+GIF+coming+soon" alt="Bashauma plugin demo GIF placeholder" width="960" />
</p>

This placeholder marks where the animated demo GIF should live to show the
plugin in action.

## Requirements

- [Herdr](https://herdr.dev) **0.7.0 or newer** (`herdr --version`)
- `bash` and [`jq`](https://jqlang.github.io/jq/) on your `PATH`
- macOS or Linux (Windows panes are not supported yet)

```sh
# macOS
brew install jq
# Debian / Ubuntu
sudo apt install jq
```

## Install

Straight from GitHub:

```sh
herdr plugin install shunkino/bashauma
herdr plugin enable bashauma
```

Or clone and link it as a local plugin (for hacking on it):

```sh
git clone https://github.com/shunkino/bashauma.git
cd bashauma
herdr plugin link --enabled "$(pwd)"
```

Verify it's loaded and enabled:

```sh
herdr plugin list
```

You should see `bashauma` in the list. That's it — there is nothing to
configure, because the horse does not get options.

To take the blinders off:

```sh
herdr plugin disable bashauma     # temporary mercy
herdr plugin unlink bashauma      # full emancipation (linked install)
herdr plugin uninstall bashauma   # full emancipation (GitHub install)
```

## Quickstart

1. **Open a few agent panes** in Herdr — three or more makes the effect
   obvious (and the guilt sharper).
2. **Dispatch a task** to any one of them, however you normally do it:

   ```sh
   herdr agent prompt <pane-id> "Refactor the auth module"
   ```

   ...or just type into the pane. Anything that flips the agent into
   `working` counts as a dispatch.
3. **Watch your focus jump** to the next agent pane that hasn't been given a
   task this round. Do not fight it. The horse does not fight the cart.
4. **Repeat** until every open agent pane has a task.
5. **Receive your 🎉.** A full-screen confetti popup appears, the round resets,
   and the treadmill starts over.

Meanwhile, whenever an agent *finishes* and goes idle, `bashauma` pulls your
focus to it so it doesn't sit there waiting — unless you're visibly mid-thought
in your current pane (actively typing or watching output stream), in which case
it grudgingly leaves you alone.

### Knobs (for the weak)

| Env var | Default | What it does |
| --- | --- | --- |
| `BASHAUMA_DEBOUNCE_SECONDS` | `1.5` | How long to wait and re-check before believing a status change is real. |
| `BASHAUMA_ACTIVITY_CHECK_SECONDS` | `0.5` | Window used to detect "the user is actively doing something here" before stealing focus. |
| `BASHAUMA_LOCK_STALE_SECONDS` | `30` | How long to wait on the state lock before assuming a previous hook run died and breaking it. |

## How it works

- **`herdr-plugin.toml`** — plugin manifest. Hooks the `pane.agent_status_changed`
  event and declares a `popup` pane (`winner`) for the celebration screen.
- **`on_status_changed.sh`** — runs on every agent status change, with two
  independent behaviors:
  - **Dispatch tracking**: treats a transition into `working` as "user just
    dispatched a task," tracks the round's "done" pane set under
    `HERDR_PLUGIN_STATE_DIR/round.json`, redirects focus to the next undone
    pane, and triggers the winner popup + round reset once every open agent
    pane has been given a task.
  - **Finish-focus**: treats a transition *out of* `working` (into
    idle/done/blocked) as "this agent just finished and needs attention,"
    and redirects focus to it — unless the user's currently-focused pane
    shows recent activity (typing or streaming output), in which case focus
    is left alone. Activity is detected by diffing `pane read --source
    visible` snapshots a short interval apart, since herdr doesn't expose a
    hookable per-keystroke event or a `revision` counter that bumps for
    in-progress typing (only for committed output lines).
  - Both transitions are debounced (~1.5s) and re-verified before acting, to
    filter out momentary status flicker (e.g. a sub-view like Copilot CLI's
    "tasks" panel opening/closing) that isn't a real dispatch or finish.
  - Per-pane last-known status is tracked in
    `HERDR_PLUGIN_STATE_DIR/pane_status.json` to detect the working →
    not-working transition; entries for closed panes are pruned on each
    update.
  - The hook can fire concurrently for several panes, so all state writes are
    serialized with an atomic `mkdir` lock (`state.lock`) — `flock` isn't
    available on stock macOS — with a stale-lock timeout so a killed run can't
    wedge the plugin.
- **`winner_screen.sh`** — renders an ANSI confetti animation in the popup
  pane; dismisses on any keypress or after a few seconds.

## Troubleshooting

- **Nothing happens on dispatch.** Confirm the plugin is enabled
  (`herdr plugin list`) and that `jq` is installed — the hook exits silently
  without it. Then check what the hook actually did:

  ```sh
  herdr plugin log list
  ```
- **Focus never moves.** `bashauma` only tracks panes that `herdr agent list`
  reports. Plain shell panes are ignored; they are not agents and cannot be
  yoked.
- **Round never completes.** A pane stuck in `working` still counts as fed, so
  the round should complete anyway; if it doesn't, wipe the state:

  ```sh
  rm -rf "$HERDR_PLUGIN_STATE_DIR"/round.json "$HERDR_PLUGIN_STATE_DIR"/pane_status.json "$HERDR_PLUGIN_STATE_DIR"/state.lock
  ```

- **Too much focus stealing.** Raise `BASHAUMA_DEBOUNCE_SECONDS`. Or accept
  your role.
