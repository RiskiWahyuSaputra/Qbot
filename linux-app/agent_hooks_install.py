#!/usr/bin/env python3
"""Pasang/lepas pemantauan agent coding di Coucou.

    agent_hooks_install.py              pasang Claude Code + OpenCode (idempoten)
    agent_hooks_install.py --uninstall  lepas entri Coucou saja
    agent_hooks_install.py --dry-run    tampilkan hasil tanpa menulis
    tambahkan --claude atau --opencode untuk memilih salah satu saja

Claude Code: hook di ~/.claude/settings.json. Hook milik pengguna tidak
disentuh (entri Coucou dikenali dari path claude_hook.py) dan settings lama
disalin ke file backup bertanggal sebelum ditulis.
OpenCode: symlink ~/.config/opencode/plugins/coucou.js → opencode/coucou.js.
"""
import json
import os
from pathlib import Path
import shlex
import shutil
import sys
import tempfile
import time

HOOK_SCRIPT = Path(__file__).resolve().with_name("claude_hook.py")
OPENCODE_PLUGIN = Path(__file__).resolve().parent / "opencode" / "coucou.js"
EVENTS = ["SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse",
          "Notification", "Stop", "SessionEnd"]
TOOL_EVENTS = {"PreToolUse", "PostToolUse"}  # butuh matcher


def settings_path():
    base = os.environ.get("CLAUDE_CONFIG_DIR") or str(Path.home() / ".claude")
    return Path(base) / "settings.json"


def is_ours(entry):
    return any("claude_hook.py" in str(h.get("command", "")) for h in entry.get("hooks", []))


def strip_ours(hooks):
    for event in list(hooks):
        entries = [e for e in hooks[event] if not (isinstance(e, dict) and is_ours(e))]
        if entries:
            hooks[event] = entries
        else:
            del hooks[event]


def install(settings):
    hooks = settings.setdefault("hooks", {})
    strip_ours(hooks)
    command = "python3 " + shlex.quote(str(HOOK_SCRIPT))
    for event in EVENTS:
        entry = {"hooks": [{"type": "command", "command": command, "timeout": 5}]}
        if event in TOOL_EVENTS:
            entry = {"matcher": "*", **entry}
        hooks.setdefault(event, []).append(entry)
    # Interaktif: izin & pertanyaan dijawab dari island (timeout > tunggu hook 90 dtk).
    interactive = {"type": "command", "command": command + " --interactive", "timeout": 120}
    hooks.setdefault("PermissionRequest", []).append({"matcher": "*", "hooks": [interactive]})
    hooks.setdefault("PreToolUse", []).append({"matcher": "AskUserQuestion", "hooks": [dict(interactive)]})


def opencode_link():
    base = os.environ.get("XDG_CONFIG_HOME") or str(Path.home() / ".config")
    return Path(base) / "opencode" / "plugins" / "coucou.js"


def opencode(uninstall, dry_run):
    link = opencode_link()
    ours = link.is_symlink() and Path(os.readlink(link)) == OPENCODE_PLUGIN
    if link.exists() and not link.is_symlink() or (link.is_symlink() and not ours):
        print("Lewati OpenCode: " + str(link) + " sudah ada dan bukan milik Coucou.", file=sys.stderr)
        return 1
    if dry_run:
        print(("Hapus " if uninstall else "Buat ") + str(link) + " → " + str(OPENCODE_PLUGIN))
        return 0
    if uninstall:
        if ours:
            link.unlink()
        print("Plugin OpenCode dilepas.")
        return 0
    link.parent.mkdir(parents=True, exist_ok=True)
    if not ours:
        link.symlink_to(OPENCODE_PLUGIN)
    print("Plugin OpenCode terpasang: " + str(link) + " (aktif di sesi OpenCode berikutnya)")
    return 0


def main(argv):
    uninstall, dry_run = "--uninstall" in argv, "--dry-run" in argv
    only_claude, only_opencode = "--claude" in argv, "--opencode" in argv
    status = 0
    if not only_claude:
        status |= opencode(uninstall, dry_run)
    if only_opencode:
        return status
    path = settings_path()
    settings = json.loads(path.read_text(encoding="utf-8")) if path.exists() else {}
    if not isinstance(settings, dict) or not isinstance(settings.get("hooks", {}), dict):
        print("settings.json tidak berbentuk object yang dikenali; dibatalkan.", file=sys.stderr)
        return 1
    if uninstall:
        strip_ours(settings.get("hooks", {}))
        if settings.get("hooks") == {}:
            del settings["hooks"]
    else:
        install(settings)
    text = json.dumps(settings, indent=2, ensure_ascii=False) + "\n"
    if dry_run:
        print(text)
        return 0
    path.parent.mkdir(parents=True, exist_ok=True)
    if path.exists():
        backup = path.with_name("settings.json.coucou-backup-" + time.strftime("%Y%m%d-%H%M%S"))
        shutil.copy2(path, backup)
        print("Backup: " + str(backup))
    fd, temp = tempfile.mkstemp(prefix=".settings-", dir=path.parent)
    with os.fdopen(fd, "w", encoding="utf-8") as stream:
        stream.write(text)
    if path.exists():
        shutil.copymode(path, temp)
    os.replace(temp, path)
    print(("Hook Claude Code dilepas dari " if uninstall else "Hook Claude Code terpasang di ") + str(path))
    return status


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
