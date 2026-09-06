#!/usr/bin/env python3
"""Install or remove Agent Workspaces.

Everything it writes is marked, so uninstall takes back exactly what install added and
nothing else. Run it as many times as you like: the second run is a no-op.

  install   agent-ws onto PATH; the Claude Code hooks; the keybindings; the login
            autostart; and the bar widget in place of Omarchy's workspace strip.
  uninstall all of the above.
"""
import contextlib, json, os, re, shutil, subprocess, sys

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

# One row per agent we can wire up. `events` maps that agent's own event name to the
# agent-ws subcommand it should call — the names are each agent's, not a shared set:
# Codex and Muse ask for the user with PermissionRequest and have no Notification at all,
# and Claude is the only one of the three with a Notification event. Every line names its
# own agent with --agent, so nothing has to be guessed from the process tree.
#   bin      what must be on PATH for this agent to count as installed
#   path     the file we write, which is that agent's own hook configuration
# In all three the hooks live under a top-level "hooks" key, so one writer serves them
# all; for Claude that key sits inside a larger settings file, which is why uninstall only
# deletes a file it made itself and finds empty again.
CLAUDE_EVENTS = {
    "SessionStart": "session-start", "SessionEnd": "session-end",
    "Notification": "notification", "UserPromptSubmit": "prompt-submit",
    "PreToolUse": "pre-tool", "Stop": "stop",
}
OTHER_EVENTS = {
    "SessionStart": "session-start", "SessionEnd": "session-end",
    "PermissionRequest": "notification", "UserPromptSubmit": "prompt-submit",
    "PreToolUse": "pre-tool", "Stop": "stop",
}
AGENT_CONFIGS = (
    {"name": "claude", "bin": "claude", "path": SETTINGS, "matcher": True,
     "events": CLAUDE_EVENTS, "label": "Claude Code"},
    {"name": "codex", "bin": "codex", "path": f"{HOME}/.codex/hooks.json", "matcher": False,
     "events": OTHER_EVENTS, "label": "Codex",
     "after": "Codex asks once, on its next start, whether to trust the new hook"},
)

BINDINGS_BLOCK = f"""{BEGIN}
{NOTE}
-- Name the workspace you are on. Enter accepts the name suggested from the session title.
o.bind("SUPER + R", "Name workspace", "agent-ws name set")
-- Forget the name. The sessions and windows stay.
o.bind("SUPER + SHIFT + R", "Clear workspace name", "agent-ws name clear")
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
def our_entry(sub, agent=None, matcher=True):
    """One hook entry, exactly as we write it. The --agent flag is what makes the reporter
    sure who fired: the line lives in that agent's own file, so it can simply say.

    Only Claude gets a matcher. Muse silently runs no hook at all from a group that has
    one — measured, by watching a live Muse window fire nothing from a file identical
    except for that key — and Codex uses a matcher to name tools, not to mean "any"."""
    cmd = f"agent-ws hook {sub}" + (f" --agent {agent}" if agent else "")
    entry = {"hooks": [{"type": "command", "command": cmd, "timeout": HOOK_TIMEOUT}]}
    return {"matcher": "*", **entry} if matcher else entry

def ours(sub, agent, matcher):
    """Every shape we have ever written for this hook. The one without --agent is what
    versions before three-agent support installed; an upgrade must still take it back."""
    return [our_entry(sub, agent, matcher), our_entry(sub, None, matcher)]

def installed(cfg):
    return shutil.which(cfg["bin"]) is not None

def backup(path):
    """A copy of the file as it was, once, before we first change it. We never restore it
    ourselves — uninstall takes back our own entries — it is there if a hand slips."""
    if not os.path.exists(path): return
    bak = f"{path}.agent-workspaces.bak"
    if os.path.exists(bak): return
    shutil.copy2(path, bak)
    record(backups=sorted(set(recorded("backups", []) + [bak])))

def hooks_install_one(cfg):
    """Add our hooks to one agent's config. Anything already there is left exactly as it
    is — including a hook of the user's own that happens to call agent-ws."""
    if not installed(cfg): return "not installed, skipped"
    path = cfg["path"]
    existed = os.path.exists(path) and open(path).read().strip()
    doc = read_json(path, {})
    if not isinstance(doc, dict): raise Bad(path)
    hooks = doc.setdefault("hooks", {})
    if not isinstance(hooks, dict): raise Bad(path)
    added = []
    for event, sub in cfg["events"].items():
        entries = hooks.setdefault(event, [])
        if not isinstance(entries, list): raise Bad(path)
        if any(e in ours(sub, cfg["name"], cfg["matcher"]) for e in entries): continue
        entries.append(our_entry(sub, cfg["name"], cfg["matcher"]))
        added.append(event)
    if added:
        backup(path)
        write_json(path, doc)
        key = f"hooks_{cfg['name']}"
        record(**{key: sorted(set(recorded(key, []) + added)),
                  f"made_{cfg['name']}": bool(recorded(f"made_{cfg['name']}")) or not existed})
    return f"added {len(added)}" if added else "already there"

def hooks_remove_one(cfg):
    """Take out exactly the entries install put in, in any shape we have ever written.
    A hook of the user's own that calls agent-ws is theirs, not ours, and stays."""
    doc = read_json(cfg["path"], {})
    if not isinstance(doc, dict): return "nothing to remove"
    hooks = doc.get("hooks", {})
    if not isinstance(hooks, dict): return "nothing to remove"
    removed = 0
    for event, sub in cfg["events"].items():
        entries = hooks.get(event)
        if not isinstance(entries, list): continue
        mine = ours(sub, cfg["name"], cfg["matcher"])
        keep = [e for e in entries if e not in mine]
        removed += len(entries) - len(keep)
        if keep: hooks[event] = keep
        else: hooks.pop(event)
    if removed:
        if not hooks: doc.pop("hooks", None)
        if recorded(f"made_{cfg['name']}") and not doc:
            remove_file(cfg["path"])
            # the folder too, if we are the ones who made it and nothing else moved in
            with contextlib.suppress(OSError): os.rmdir(os.path.dirname(cfg["path"]))
        else: write_json(cfg["path"], doc)
    for bak in recorded("backups", []):
        if bak == f"{cfg['path']}.agent-workspaces.bak": remove_file(bak)
    return f"removed {removed}" if removed else "none of ours found"

MUSE_PLUGIN = "agent-workspaces"

def muse(*args):
    """Run one of Muse's own plugin commands, in the user's environment."""
    return subprocess.run(["muse", "plugins", *args], capture_output=True, text=True)

def muse_install(src):
    """Muse reads a hook file only from the folder you are working in, so there is no
    single file we could write that would cover every project — measured, by watching a
    live Muse window fire nothing from a hook file in every other place it might look.
    Its supported way to add something once, for the whole account, is a plugin, which is
    what we ship. Installing resets its trust, so approving always follows installing."""
    if not shutil.which("muse"): return "not installed, skipped"
    bundle = f"{src}/muse-plugin"
    if not os.path.isdir(bundle): return "the plugin is missing from this download"
    r = muse("install", bundle, "--scope", "user")
    if r.returncode != 0: return f"muse refused it: {r.stderr.strip().splitlines()[-1:] or ''}"
    a = muse("approve", MUSE_PLUGIN)
    if a.returncode != 0: return f"installed, but muse would not approve it: {a.stderr.strip()}"
    record(muse_plugin=True)
    return "installed and approved"

def muse_remove():
    """Only ever remove the plugin we put there ourselves."""
    if not shutil.which("muse"): return "none found"
    if not recorded("muse_plugin"): return "none of ours found"
    r = muse("remove", MUSE_PLUGIN)
    return "removed" if r.returncode == 0 else f"muse would not remove it: {r.stderr.strip()}"

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
    for cfg in AGENT_CONFIGS:
        say(f"{cfg['label']} hooks …", step(hooks_install_one, cfg))
    say("Muse Code hooks …", step(muse_install, src))
    say("keybindings …", step(block, BINDINGS, BINDINGS_BLOCK))
    say("login autostart …", step(block, AUTOSTART, AUTOSTART_BLOCK))
    say("bar widget …", step(bar_install))
    print()
    say("Super+R names the workspace you are on; Super+Shift+R forgets the name;")
    say("Super+Shift+Alt+R resets it. None of those three are bound by Omarchy.")
    say("`agent-ws launch` opens a session in the workspace you are on, or brings back the")
    say("ones a named workspace remembers. It is deliberately not bound to anything — pick")
    say("your own key for it. See the README.")
    for cfg in AGENT_CONFIGS:
        if cfg.get("after") and installed(cfg): say("note:", cfg["after"] + ".")
    if os.path.expanduser("~/.local/bin") not in os.environ.get("PATH", "").split(":"):
        say("note: ~/.local/bin is not on your PATH; the keybindings will not find agent-ws")
    reload_hypr(); restart_shell()
    print("\nDone. Super+R names the workspace you are on. Open Claude anywhere and watch the bar.")

def uninstall(src):
    print("Removing Agent Workspaces")
    say("bar widget …", step(bar_remove))
    for cfg in AGENT_CONFIGS:
        say(f"{cfg['label']} hooks …", step(hooks_remove_one, cfg))
    say("Muse Code hooks …", step(muse_remove))
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
