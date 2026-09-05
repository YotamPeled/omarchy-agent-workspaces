# Agent Workspaces

**Your OS is the harness.** No tmux, no session manager, no second window listing what is
running. Omarchy's workspace strip becomes the thing that tells you what every Claude Code
session is doing — because the workspaces are already there, already on screen, and already
one keystroke apart.

```
▣  1 boxes-orbit   2 lovable   3 workspaces   4 ui-expert   5   ▶   X
   ˙              ˙           ●              ˙
```

Each workspace holding a Claude Code session shows a short name for it and a mark for what
it is doing. A workspace with nothing in it stays a plain, dim number.

## What the marks mean

| Mark | Meaning |
|---|---|
| A dot that breathes | the session is working |
| A still, dim dot | the session is idle, waiting for you to type |
| A rule under the number | the session needs you: a permission prompt, an elicitation |
| A rule above the number and name | this is the workspace you are on |

Several sessions can share a workspace. The slot shows the focused one's name and the worst
state of the group, so a workspace never looks calm while something in it is stuck. Hover it
to see them all.

Every mark takes its colour from your active Omarchy theme. Change the theme and the strip
changes with it.

## Names

A session names its own workspace. The name comes from the title Claude gives the chat:
first a name derived on the spot, then a better one from Haiku about seven seconds later,
cached so a title costs one call ever.

- `Localsend not finding iPhone on omarchy` → `localsend-ios`
- `Build story engine compose.py with beat vocabulary` → `compose-beats`
- `Skip permissions dangerously` → `perms-danger`

Close the session and the name goes with it — unless you gave the workspace a name yourself,
in which case it stays, and so does the workspace's memory of what ran in it.

## Keys

| Key | What it does |
|---|---|
| `Super + R` | Name this workspace. Enter accepts the suggestion. |
| `Super + Shift + R` | Forget the name. Sessions and windows stay. |
| `Super + Shift + A` | Bring back the sessions this workspace remembers. Press again once they are open and you get a fresh one alongside them. |
| `Super + Shift + Alt + R` | Reset: forget the name, forget what it remembered, close its Claude windows. Asks first. |

## Pinned workspaces

A workspace can be pinned to an app: an icon replaces the number, and the app opens there.
Put them in `~/.config/omarchy/workspace-names.json`:

```json
{
  "2": "rss-digest",
  "7": { "icon": "youtube", "label": "YouTube" },
  "8": { "icon": "x", "label": "X" }
}
```

Then add a Hyprland rule so the app always lands there, and an autostart line so it opens at
login. `install` does not do this part for you — which app goes where is yours to choose.

```lua
-- ~/.config/hypr/hyprland.lua
o.window("^chrome-youtube\\.com__.*$", { workspace = "7 silent" })

-- ~/.config/hypr/autostart.lua
o.exec_on_start(o.launch_webapp_sole("^chrome-youtube\\.com__.*$", "https://youtube.com/"))
```

## Install

```bash
omarchy plugin add https://github.com/YotamPeled/omarchy-agent-workspaces.git
~/.config/omarchy/plugins/agentws.workspaces/install
```

The first command installs the bar widget. The second puts `agent-ws` on your PATH, adds the
five Claude Code hooks to `~/.claude/settings.json`, adds the keybindings, and swaps our
widget in for Omarchy's workspace strip. It only ever adds what is missing, so running it
twice is safe.

To remove it:

```bash
~/.config/omarchy/plugins/agentws.workspaces/uninstall
omarchy plugin remove agentws.workspaces
```

Uninstall takes back exactly what install added — your other hooks, your other keybindings
and the rest of your `shell.json` are untouched. It leaves your state directory alone; delete
`~/.local/state/omarchy/agent-workspaces` yourself if you want it gone.

## How it works

Nothing here patches Omarchy. The widget is a normal shell plugin in `~/.config/omarchy/`,
loaded after the packaged defaults, so an `omarchy update` cannot break it.

`agent-ws` is one small Python program that owns every fact the bar needs, in three JSON
files under `~/.local/state/omarchy/agent-workspaces/`. Claude Code hooks feed it: session
start and end, notifications, prompts, tool calls. The bar reads those files and watches
Hyprland; it never asks Claude anything.

The "working" and "idle" marks do not come from a hook at all. Claude already writes a status
glyph into its terminal title, so the bar reads the titles Hyprland is holding anyway. That
is why the state is instant and costs nothing.

## Requirements

Omarchy with the Quickshell bar, Hyprland, Python 3, and Claude Code. `~/.local/bin` on your
PATH.

## Licence

MIT.
