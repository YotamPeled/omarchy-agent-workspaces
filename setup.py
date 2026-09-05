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
PLUGIN_ID = "agentws.workspaces"
BIN = f"{HOME}/.local/bin/agent-ws"
SETTINGS = f"{HOME}/.claude/settings.json"
SHELL_JSON = f"{HOME}/.config/omarchy/shell.json"
BINDINGS = f"{HOME}/.config/hypr/bindings.lua"
AUTOSTART = f"{HOME}/.config/hypr/autostart.lua"
BEGIN, END = "-- >>> agent-workspaces", "-- <<< agent-workspaces"

HOOKS = {                                    # Claude Code event -> agent-ws subcommand
    "SessionStart": "session-start", "SessionEnd": "session-end",
    "Notification": "notification", "UserPromptSubmit": "prompt-submit",
    "PreToolUse": "pre-tool",
}

BINDINGS_BLOCK = f"""{BEGIN}
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
-- Hyprland forgets workspace names when it restarts; put the saved ones back.
o.launch_on_start("agent-ws name apply")
{END}"""


# ---------- small helpers ----------
def say(*a): print(" ", *a)

def read_json(path, default):
    try:
        with open(path) as f: text = f.read()
    except OSError: return default
    if not text.strip(): return default
    try: return json.loads(text)
    except ValueError:
        sys.exit(f"{path} is not valid JSON. Fix it first; refusing to write over it.")

def write_json(path, data):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    tmp = f"{path}.{os.getpid()}.tmp"
    with open(tmp, "w") as f: json.dump(data, f, indent=2); f.write("\n")
    os.replace(tmp, path)

def block(path, text):
    """Add our marked block to a file, or replace the one already there."""
    cur = open(path).read() if os.path.exists(path) else ""
    if BEGIN in cur:
        new = re.sub(re.escape(BEGIN) + r".*?" + re.escape(END), text, cur, flags=re.S)
    else:
        new = cur.rstrip("\n") + "\n\n" + text + "\n"
    if new != cur:
        os.makedirs(os.path.dirname(path), exist_ok=True)
        open(path, "w").write(new)
        return True
    return False

def unblock(path):
    if not os.path.exists(path): return False
    cur = open(path).read()
    new = re.sub(r"\n*" + re.escape(BEGIN) + r".*?" + re.escape(END) + r"\n*", "\n", cur, flags=re.S)
    if new != cur:
        open(path, "w").write(new)
        return True
    return False


# ---------- the pieces ----------
def hooks_install():
    """Add our five hooks. Anything already in settings.json is left exactly as it is."""
    s = read_json(SETTINGS, {})
    hooks = s.setdefault("hooks", {})
    added = 0
    for event, sub in HOOKS.items():
        cmd = f"agent-ws hook {sub}"
        entries = hooks.setdefault(event, [])
        if any(cmd == h.get("command") for e in entries for h in e.get("hooks", [])):
            continue
        entries.append({"matcher": "*",
                        "hooks": [{"type": "command", "command": cmd, "timeout": 10}]})
        added += 1
    if added: write_json(SETTINGS, s)
    return added

def hooks_remove():
    s = read_json(SETTINGS, {})
    hooks = s.get("hooks", {})
    removed = 0
    for event in list(hooks):
        keep = []
        for entry in hooks[event]:
            inner = [h for h in entry.get("hooks", [])
                     if not str(h.get("command", "")).startswith("agent-ws hook ")]
            if len(inner) != len(entry.get("hooks", [])): removed += 1
            if inner:
                entry["hooks"] = inner
                keep.append(entry)
        if keep: hooks[event] = keep
        else: hooks.pop(event)
    if removed:
        if not hooks: s.pop("hooks", None)
        write_json(SETTINGS, s)
    return removed

def bar_install():
    """Put our widget where Omarchy's workspace strip was, without disturbing the rest."""
    s = read_json(SHELL_JSON, {})
    left = s.setdefault("bar", {}).setdefault("layout", {}).setdefault("left", [])
    ids = [w.get("id") if isinstance(w, dict) else w for w in left]
    if PLUGIN_ID in ids: return False
    stock = next((i for i, w in enumerate(ids) if w == "omarchy.workspaces"), None)
    if stock is not None: left[stock] = {"id": PLUGIN_ID}
    else: left.append({"id": PLUGIN_ID})
    write_json(SHELL_JSON, s)
    return True

def bar_remove():
    s = read_json(SHELL_JSON, {})
    left = s.get("bar", {}).get("layout", {}).get("left", [])
    ids = [w.get("id") if isinstance(w, dict) else w for w in left]
    if PLUGIN_ID not in ids: return False
    left[ids.index(PLUGIN_ID)] = {"id": "omarchy.workspaces"}
    write_json(SHELL_JSON, s)
    return True

def bin_install(src):
    os.makedirs(os.path.dirname(BIN), exist_ok=True)
    want = open(f"{src}/bin/agent-ws").read()
    if os.path.exists(BIN) and open(BIN).read() == want: return False
    shutil.copyfile(f"{src}/bin/agent-ws", BIN)
    os.chmod(BIN, 0o755)
    return True

def restart_shell():
    if os.environ.get("AGENT_WS_NO_RELOAD"): return   # set by the test harness
    subprocess.run(["omarchy", "restart", "shell"], capture_output=True)

def reload_hypr():
    if os.environ.get("AGENT_WS_NO_RELOAD"): return
    subprocess.run(["hyprctl", "reload"], capture_output=True)


# ---------- commands ----------
def install(src):
    print("Agent Workspaces")
    say("agent-ws ->", BIN, "…", "installed" if bin_install(src) else "already current")
    n = hooks_install();  say("Claude Code hooks …", f"added {n}" if n else "already there")
    say("keybindings …", "added" if block(BINDINGS, BINDINGS_BLOCK) else "already there")
    say("login autostart …", "added" if block(AUTOSTART, AUTOSTART_BLOCK) else "already there")
    say("bar widget …", "placed" if bar_install() else "already placed")
    if os.path.expanduser("~/.local/bin") not in os.environ.get("PATH", "").split(":"):
        say("note: ~/.local/bin is not on your PATH; the keybindings will not find agent-ws")
    reload_hypr(); restart_shell()
    print("\nDone. Super+R names the workspace you are on. Open Claude anywhere and watch the bar.")

def uninstall(src):
    print("Removing Agent Workspaces")
    say("bar widget …", "restored to Omarchy's" if bar_remove() else "was not placed")
    n = hooks_remove(); say("Claude Code hooks …", f"removed {n}" if n else "none found")
    say("keybindings …", "removed" if unblock(BINDINGS) else "none found")
    say("login autostart …", "removed" if unblock(AUTOSTART) else "none found")
    if os.path.exists(BIN): os.remove(BIN); say("agent-ws …", "removed")
    else: say("agent-ws …", "not installed")
    say("state kept at ~/.local/state/omarchy/agent-workspaces (delete it yourself if you want)")
    reload_hypr(); restart_shell()
    print("\nDone. `omarchy plugin remove agentws.workspaces` takes the widget files too.")

if __name__ == "__main__":
    if len(sys.argv) < 3: sys.exit(__doc__)
    {"install": install, "uninstall": uninstall}[sys.argv[1]](sys.argv[2])
