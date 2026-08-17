# bashauma

A [Herdr](https://herdr.dev) plugin that nudges you to give every open agent
tab a task before you tunnel-vision on just one. Every time you dispatch a
task to an agent pane, `bashauma` marks that pane done for the round and
auto-focuses the next agent pane that still needs one. Once every open agent
has a task, it pops up a full-screen 🎉/🎊 celebration.

See [`prd.md`](./prd.md) for the full product spec.

## Demo

<p align="center">
  <img src="https://placehold.co/960x540/1f2937/ffffff?text=Bashauma+demo+GIF+coming+soon" alt="Bashauma plugin demo GIF placeholder" width="960" />
</p>

This placeholder marks where the animated demo GIF should live to show the
plugin in action.

## How it works

- **`herdr-plugin.toml`** — plugin manifest. Hooks the `pane.agent_status_changed`
  event and declares a `popup` pane (`winner`) for the celebration screen.
- **`on_status_changed.sh`** — runs on every agent status change. Treats a
  transition into `working` as "user just dispatched a task," tracks the
  round's "done" pane set under `HERDR_PLUGIN_STATE_DIR/round.json`, redirects
  focus to the next undone pane, and triggers the winner popup + round reset
  once every open agent pane has been given a task.
- **`winner_screen.sh`** — renders an ANSI confetti animation in the popup
  pane; dismisses on any keypress or after a few seconds.

## Local install / testing

```sh
herdr plugin link --enabled "$(pwd)"
herdr plugin list
```

Dispatch a task to an agent pane as usual (e.g. `herdr agent prompt <pane> "..."`)
and watch focus jump to the next pending pane. Give every open agent a task to
see the winner popup.
