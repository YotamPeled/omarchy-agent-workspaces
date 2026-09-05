#!/usr/bin/env python3
"""Install or remove Agent Workspaces.

Everything it writes is marked, so uninstall takes back exactly what install added and
nothing else. Run it as many times as you like: the second run is a no-op.

  install   agent-ws onto PATH; the Claude Code hooks; the keybindings; the login
            autostart; and the bar widget in place of Omarchy's workspace strip.
  uninstall all of the above.
"""
import json, os, re, shutil, subprocess, sys

HOME = os.path.expanduser("~")
PLUGIN_ID = "io.github.yotampeled.agent-workspaces"
BIN = f"{HOME}/.local/bin/agent-ws"
SETTINGS = f"{HOME}/.claude/settings.json"
SHELL_JSON = f"{HOME}/.config/omarchy/shell.json"
BINDINGS = f"{HOME}/.config/hypr/bindings.lua"
AUTOSTART = f"{HOME}/.config/hypr/autostart.lua"
BEGIN, END = "-- >>> agent-workspaces", "-- <<< agent-workspaces"
NOTE = "-- Managed by Agent Workspaces. Edits inside this block are lost on reinstall."
STATE = f"{HOME}/.local/state/omarchy/agent-workspaces"
RECORD = f"{STATE}/install.json"          # what we changed, so uninstall can undo just that
HOOK_TIMEOUT = 10

HOOKS = {                                    # Claude Code event -> agent-ws subcommand
    "SessionStart": "session-start", "SessionEnd": "session-end",
    "Notification": "notification", "UserPromptSubmit": "prompt-submit",
    "PreToolUse": "pre-tool",
}

BINDINGS_BLOCK = f"""{BEGIN}
{NOTE}
-- Name the workspace you are on. Enter accepts the name suggested from the session title.
o.bind("SUPER + R", "Name workspace", "agent-ws name set")
-- Forget the name. The sessions and windows stay.
o.bind("SUPER + SHIFT + R", "Clear workspace name", "agent-ws name clear")
-- In a named workspace, bring back the sessions it remembers. Press it again once they are
-- open and you get a fresh one alongside them.
o.bind("SUPER + SHIFT + A", "Agent", "agent-ws launch")
-- Bigger hammer: forget the name, forget what the workspace remembered, close its Claude
-- windows. Asks first, because closing the windows is the part you cannot get back.
o.bind("SUPER + SHIFT + ALT + R", "Reset workspace", "agent-ws reset")
{END}"""

AUTOSTART_BLOCK = f"""{BEGIN}
{NOTE}
-- Hyprland forgets workspace names when it restarts; put the saved ones back.
o.launch_on_start("agent-ws name apply")
{END}"""


# ---------- small helpers ----------
class Bad(Exception):
    """The file is there but is not JSON. Never write over one of these."""

def say(*a): print(" ", *a)

def step(fn, *a):
    """Run one step. A step that cannot read its file says so and lets the others run."""
    try: return fn(*a)
    except Bad as e: return f"skipped: {e.args[0]} is not valid JSON, fix it and run again"

def record(**kw):
    os.makedirs(STATE, exist_ok=True)
    r = {}
    try: r = json.load(open(RECORD))
    except (OSError, ValueError): pass
    r.update(kw); write_json(RECORD, r)

def recorded(key, default=None):
    try: return json.load(open(RECORD)).get(key, default)
    except (OSError, ValueError): return default

def read_json(path, default):
    try:
        with open(path) as f: text = f.read()
    except OSError: return default
    if not text.strip(): return default
    try: return json.loads(text)
    except ValueError: raise Bad(path)

def write_json(path, data):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    tmp = f"{path}.{os.getpid()}.tmp"
    with open(tmp, "w") as f: json.dump(data, f, indent=2); f.write("\n")
    os.replace(tmp, path)

def markers_ok(cur, path):
    b, e = cur.count(BEGIN), cur.count(END)
    if b == e and b <= 1: return True
    print(f"    the {BEGIN} / {END} markers in {path} are {b} and {e}; "
          "remove the block by hand and run again")
    return False

def block(path, text):
    """Add our marked block to a file, or replace the one already there."""
    cur = open(path).read() if os.path.exists(path) else ""
    if not markers_ok(cur, path): return "skipped, markers are damaged"
    if BEGIN in cur:
        new = re.sub(re.escape(BEGIN) + r".*?" + re.escape(END), text, cur, flags=re.S)
    else:
        new = cur.rstrip("\n") + "\n\n" + text + "\n"
    if new == cur: return "already there"
    os.makedirs(os.path.dirname(path), exist_ok=True)
    open(path, "w").write(new)
    return "added"

def unblock(path):
    if not os.path.exists(path): return "none found"
    cur = open(path).read()
    if not markers_ok(cur, path): return "skipped, markers are damaged"
    new = re.sub(r"\n*" + re.escape(BEGIN) + r".*?" + re.escape(END) + r"\n*", "\n", cur, flags=re.S)
    if new == cur: return "none found"
    open(path, "w").write(new)
    return "removed"


# ---------- the pieces ----------
def our_entry(sub):
    return {"matcher": "*",
            "hooks": [{"type": "command", "command": f"agent-ws hook {sub}",
                       "timeout": HOOK_TIMEOUT}]}

def hooks_install():
    """Add our five hooks. Anything already in settings.json is left exactly as it is —
    including a hook of the user's own that happens to call agent-ws."""
    existed = os.path.exists(SETTINGS) and open(SETTINGS).read().strip()
    s = read_json(SETTINGS, {})
    hooks = s.setdefault("hooks", {})
    added = []
    for event, sub in HOOKS.items():
        entries = hooks.setdefault(event, [])
        if our_entry(sub) in entries: continue
        entries.append(our_entry(sub))
        added.append(event)
    if added:
        write_json(SETTINGS, s)
        record(hooks=sorted(set(recorded("hooks", []) + added)),
               settings_made=bool(recorded("settings_made")) or not existed)
    return f"added {len(added)}" if added else "already there"

def hooks_remove():
    """Take out exactly the entries install put in. A hook of the user's own that calls
    agent-ws is theirs, not ours, and stays."""
    s = read_json(SETTINGS, {})
    hooks = s.get("hooks", {})
    if not isinstance(hooks, dict): return "nothing to remove"
    removed = 0
    for event, sub in HOOKS.items():
        entries = hooks.get(event)
        if not isinstance(entries, list): continue
        keep = [e for e in entries if e != our_entry(sub)]
        removed += len(entries) - len(keep)
        if keep: hooks[event] = keep
        else: hooks.pop(event)
    if removed:
        if not hooks: s.pop("hooks", None)
        if recorded("settings_made") and not s: remove_file(SETTINGS)
        else: write_json(SETTINGS, s)
    return f"removed {removed}" if removed else "none of ours found"

def prune_empty(s, made):
    """Drop the containers install had to invent, if nothing else moved into them."""
    if "left" in made and s.get("bar", {}).get("layout", {}).get("left") == []:
        s["bar"]["layout"].pop("left")
    if "layout" in made and s.get("bar", {}).get("layout") == {}: s["bar"].pop("layout")
    if "bar" in made and s.get("bar") == {}: s.pop("bar")

def remove_file(path):
    try: os.remove(path)
    except OSError: pass

def sections(s):
    layout = s.get("bar", {}).get("layout", {})
    if not isinstance(layout, dict): return []
    return [(k, v) for k, v in layout.items() if isinstance(v, list)]

def widget_id(w): return w.get("id") if isinstance(w, dict) else w

def bar_install():
    """Take over Omarchy's workspace strip wherever it is, and write down exactly what we
    replaced — and which containers we had to invent — so uninstall puts back just that."""
    existed = os.path.exists(SHELL_JSON)
    s = read_json(SHELL_JSON, {})
    for name, items in sections(s):
        if any(widget_id(w) == PLUGIN_ID for w in items): return "already placed"
    for name, items in sections(s):
        for i, w in enumerate(items):
            if widget_id(w) == "omarchy.workspaces":
                items[i] = {"id": PLUGIN_ID}
                write_json(SHELL_JSON, s)
                record(bar={"section": name, "index": i, "replaced": w})
                return f"replaced Omarchy's strip in the {name} section"
    made = [k for k in ("bar", "layout", "left")
            if k not in (s if k == "bar" else s.get("bar", {}) if k == "layout"
                         else s.get("bar", {}).get("layout", {}))]
    left = s.setdefault("bar", {}).setdefault("layout", {}).setdefault("left", [])
    if not isinstance(left, list): return "skipped: bar.layout.left is not a list"
    left.append({"id": PLUGIN_ID})
    write_json(SHELL_JSON, s)
    record(bar={"section": "left", "index": len(left) - 1, "replaced": None,
                "made": made, "file_made": not existed})
    return "added to the left section"

def bar_remove():
    """Undo exactly what bar_install did. If it added us where nothing was, take us out
    rather than inventing a widget the user never had."""
    s = read_json(SHELL_JSON, {})
    was = recorded("bar")
    for name, items in sections(s):
        for i, w in enumerate(items):
            if widget_id(w) != PLUGIN_ID: continue
            if was and was.get("replaced") is not None: items[i] = was["replaced"]
            else: items.pop(i)
            prune_empty(s, (was or {}).get("made", []))
            if (was or {}).get("file_made") and not s: remove_file(SHELL_JSON)
            else: write_json(SHELL_JSON, s)
            return "put Omarchy's strip back" if was and was.get("replaced") else "removed"
    return "was not placed"

def bin_install(src):
    """Never overwrite somebody else's agent-ws without keeping a copy of it."""
    os.makedirs(os.path.dirname(BIN), exist_ok=True)
    want = open(f"{src}/bin/agent-ws").read()
    note = ""
    if os.path.exists(BIN):
        have = open(BIN).read()
        if have == want: return "already current"
        if not recorded("bin"):
            shutil.copyfile(BIN, BIN + ".before-agent-workspaces")
            note = f" (kept your existing one at {BIN}.before-agent-workspaces)"
    shutil.copyfile(f"{src}/bin/agent-ws", BIN)
    os.chmod(BIN, 0o755)
    record(bin=True)
    return "installed" + note

def bin_remove():
    if not os.path.exists(BIN): return "not installed"
    os.remove(BIN)
    back = BIN + ".before-agent-workspaces"
    if os.path.exists(back):
        os.replace(back, BIN); os.chmod(BIN, 0o755)
        return "removed, and your earlier one put back"
    return "removed"

def restart_shell():
    if os.environ.get("AGENT_WS_NO_RELOAD"): return   # set by the test harness
    subprocess.run(["omarchy", "restart", "shell"], capture_output=True)

def reload_hypr():
    if os.environ.get("AGENT_WS_NO_RELOAD"): return
    subprocess.run(["hyprctl", "reload"], capture_output=True)


# ---------- commands ----------
def install(src):
    print("Agent Workspaces")
    say("agent-ws ->", BIN, "…", step(bin_install, src))
    say("Claude Code hooks …", step(hooks_install))
    say("keybindings …", step(block, BINDINGS, BINDINGS_BLOCK))
    say("login autostart …", step(block, AUTOSTART, AUTOSTART_BLOCK))
    say("bar widget …", step(bar_install))
    print()
    say("Super+Shift+A now opens Claude — it replaces Omarchy's default binding for ChatGPT.")
    say("It runs plain `claude`. To pass your own flags, or start somewhere other than the")
    say("home directory, write ~/.config/omarchy/agent-workspaces.json:")
    say('  {"launch": ["claude", "--dangerously-skip-permissions"], "cwd": "~/code"}')
    if os.path.expanduser("~/.local/bin") not in os.environ.get("PATH", "").split(":"):
        say("note: ~/.local/bin is not on your PATH; the keybindings will not find agent-ws")
    reload_hypr(); restart_shell()
    print("\nDone. Super+R names the workspace you are on. Open Claude anywhere and watch the bar.")

def uninstall(src):
    print("Removing Agent Workspaces")
    say("bar widget …", step(bar_remove))
    say("Claude Code hooks …", step(hooks_remove))
    say("keybindings …", step(unblock, BINDINGS))
    say("login autostart …", step(unblock, AUTOSTART))
    say("agent-ws …", step(bin_remove))
    # our own bookkeeping goes; the session state stays, it is the user's
    try: os.remove(RECORD)
    except OSError: pass
    say("state kept at ~/.local/state/omarchy/agent-workspaces (delete it yourself if you want)")
    reload_hypr(); restart_shell()
    print("\nDone. `omarchy plugin remove io.github.yotampeled.agent-workspaces` takes the widget files too.")

if __name__ == "__main__":
    if len(sys.argv) < 3: sys.exit(__doc__)
    {"install": install, "uninstall": uninstall}[sys.argv[1]](sys.argv[2])
