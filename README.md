# Agent Workspaces

**Your OS is the harness.** No tmux, no session manager, no second window listing what is
running. Omarchy's workspace strip becomes the thing that tells you what every Claude Code
session is doing — because the workspaces are already there, already on screen, and already
one keystroke apart.

![The workspace strip: four named sessions, one working, one waiting on you](preview.png)

Four pieces of work, one glance: the PDF export is running, the checkout bug is waiting on
you, the API retry and the RAG eval are idle. A workspace with nothing in it stays a plain,
dim number.

## What the marks mean

| Mark | Meaning |
|---|---|
| A bright dot | the session is working |
| A dim dot | the session is idle, waiting for you to type |
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

The better name costs one `claude -p` call per distinct title. **The window title is sent to
the Anthropic API** — nothing else: not the transcript, not your working directory, not the
session id. Claude renames a chat as it goes, so a long session may cost a few calls over its
life, one per new title. Set `AGENT_WS_NO_AI=1` to turn this off and keep the plain derived
names, which need no network at all.

Close the session and the name goes with it — unless you gave the workspace a name yourself,
in which case it stays, and so does the workspace's memory of what ran in it.

## Keys

| Key | What it does |
|---|---|
| `Super + R` | Name this workspace. Enter accepts the suggestion. |
| `Super + Shift + R` | Forget the name. Sessions and windows stay. |
| `Super + Shift + A` | Bring back the sessions this workspace remembers. Press again once they are open and you get a fresh one alongside them. **This replaces Omarchy's default binding, which opens ChatGPT.** |
| `Super + Shift + Alt + R` | Reset: forget the name, forget what it remembered, close its Claude windows. Asks first whenever anything would be lost — including when the windows are already closed but the workspace still remembers them. |

`Super + Shift + A` runs plain `claude`. To give it your own flags, or start it somewhere
other than your home directory, write `~/.config/omarchy/agent-workspaces.json`:

```json
{ "launch": ["claude", "--dangerously-skip-permissions"], "cwd": "~/code" }
```

Workspace names you set yourself live in `~/.config/omarchy/workspace-names.json`, one line
per workspace, and survive reboots:

```json
{ "2": "rss-digest", "4": "matchstory" }
```

It only ever closes a window it can tie to a session it started. A window it does not
recognise is left alone, even if it is sitting in the workspace you are resetting.

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

Uninstall takes back what install added and only that. It matches its own hook entries
exactly, so a hook of your own that also calls `agent-ws` survives. It writes Omarchy's
workspace strip back into the exact slot it took, in whichever bar section that was — and if
install had nothing to replace, uninstall removes our widget rather than inventing one. Files
install created on a bare machine are deleted again rather than left as empty husks. If one
of your config files has a syntax error, uninstall says so and carries on with the rest
instead of stopping half-done.

`shell.json` and `settings.json` come back with the same content but reformatted at two-space
indent, which is Omarchy's own style. Your state directory is left alone; delete
`~/.local/state/omarchy/agent-workspaces` yourself if you want it gone.

`test/sandbox-install.sh` and `test/edge-cases.sh` prove all of this against a throwaway home
directory. Run them.

## How it works

Nothing here patches Omarchy. The widget is a normal shell plugin in `~/.config/omarchy/`,
loaded after the packaged defaults, so an `omarchy update` cannot break it.

Install does edit three files you own — `~/.claude/settings.json`, `~/.config/hypr/bindings.lua`
and `~/.config/hypr/autostart.lua` — plus your `shell.json`. Everything it adds is marked, and
uninstall takes back exactly those marks.

`agent-ws` is one small Python program that owns every fact the bar needs, in JSON files under
`~/.local/state/omarchy/agent-workspaces/` (sessions, needs, name cache, plus lock files and a
small debug log). Claude Code hooks feed it: session start and end, notifications, prompts,
tool calls. The bar reads those files and watches Hyprland; it never asks Claude anything.

The "working" and "idle" marks do not come from a hook at all. Claude already writes a status
glyph into its terminal title, so the bar reads the titles Hyprland is holding anyway. That is
why the state is instant and costs nothing. The flip side: any window whose title happens to
start with `◐ ◑ ◒ ◓ ✳` is *shown* as a session. It will not be closed by a reset — that needs
a real session record — but it will occupy a slot until you retitle it.

## Requirements

Omarchy with the Quickshell bar, Hyprland, Python 3, and Claude Code. `~/.local/bin` on your
PATH. `omarchy-launch-tui` and `omarchy menu` come with Omarchy and are used for opening
sessions and for the reset confirmation.

## Licence

MIT.
