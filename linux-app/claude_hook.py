#!/usr/bin/env python3
"""Relay hook Claude Code → bridge Coucou (status sesi di island).

Dipasang oleh agent_hooks_install.py. Mode biasa: kirim satu event ringkas,
keluar 0 tanpa output (tidak pernah mengubah perilaku Claude Code).

Mode interaktif (`--interactive`, untuk PermissionRequest dan PreToolUse
AskUserQuestion): tampilkan kartu di island dan tunggu jawaban. Hanya bila
pengguna menjawab di island, hook mencetak keputusan JSON; bila Coucou mati,
waktu habis, atau dipilih "Jawab di terminal", hook diam dan Claude Code
bertanya di terminal seperti biasa.
"""
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

TIMEOUT = 0.4
# Lama menunggu jawaban island sebelum dikembalikan ke terminal (detik).
WAIT = int(os.environ.get("HERMES_COUCOU_CLAUDE_WAIT", "90") or 90)


def short(text, limit=80):
    text = " ".join(str(text or "").split())
    return text if len(text) <= limit else text[:limit - 1] + "…"


def tool_summary(tool_name, tool_input):
    """'Bash: git status' / 'Edit: main.ts' — cukup untuk dibaca sekilas."""
    if not isinstance(tool_input, dict):
        return tool_name
    detail = tool_input.get("command") or tool_input.get("description")
    if not detail:
        path = tool_input.get("file_path") or tool_input.get("path") or tool_input.get("notebook_path")
        detail = os.path.basename(str(path)) if path else tool_input.get("pattern") or tool_input.get("url")
    return tool_name + (": " + short(detail, 60) if detail else "")


def build(hook):
    name = hook.get("hook_event_name")
    tool = str(hook.get("tool_name") or "")
    if name == "SessionStart":
        return "AgentSessionStart", "Sesi dimulai", "", ""
    if name == "UserPromptSubmit":
        return "AgentPrompt", short(hook.get("prompt")) or "Prompt baru", "", ""
    if name == "PreToolUse":
        return "AgentToolStart", tool_summary(tool, hook.get("tool_input")), tool, ""
    if name == "PostToolUse":
        return "AgentToolDone", tool_summary(tool, hook.get("tool_input")), tool, ""
    if name == "Notification":
        message = short(hook.get("message"), 120) or "Claude Code butuh input"
        kind = hook.get("notification_type") or ""
        if kind not in ("permission_prompt", "idle_prompt"):
            kind = "permission_prompt" if "permission" in message.lower() else "idle_prompt"
        return "AgentWaiting", message, "", "permission" if kind == "permission_prompt" else "input"
    if name == "Stop":
        return "AgentStop", "Giliran selesai", "", ""
    if name == "SessionEnd":
        return "AgentSessionEnd", str(hook.get("reason") or "Sesi berakhir"), "", ""
    return None


def ask_island(hook, kind, title, detail, questions=None, can_always=False):
    from bridge_client import request
    cwd = str(hook.get("cwd") or "")
    result = request("POST", "/agent/request", {
        "agent": "claude", "kind": kind, "request_id": os.urandom(8).hex(),
        "session_id": str(hook.get("session_id") or ""),
        "project": os.path.basename(cwd.rstrip("/")) or cwd,
        "title": title, "detail": detail, "questions": questions, "can_always": can_always,
        "timeout": WAIT,
    }, timeout=WAIT + 10)
    if not isinstance(result, dict) or result.get("status") != "answered":
        return None
    answer = result.get("answer") or {}
    return None if answer.get("decision") == "terminal" else answer


def interactive(hook):
    """Kembalikan dict output hook, atau None untuk membiarkan terminal yang bertanya."""
    name = hook.get("hook_event_name")
    tool = str(hook.get("tool_name") or "")
    tool_input = hook.get("tool_input") if isinstance(hook.get("tool_input"), dict) else {}
    if name == "PreToolUse" and tool == "AskUserQuestion":
        questions = tool_input.get("questions")
        if not isinstance(questions, list) or not questions:
            return None
        answer = ask_island(hook, "question", "Claude Code bertanya", "", [
            {"question": q.get("question"), "header": q.get("header"), "options": q.get("options") or [],
             "multiSelect": bool(q.get("multiSelect"))} for q in questions if isinstance(q, dict)])
        if not answer:
            return None
        answers = {q.get("question"): ", ".join(picked)
                   for q, picked in zip(questions, answer.get("answers") or [])}
        return {"hookSpecificOutput": {"hookEventName": "PreToolUse", "permissionDecision": "allow",
                                       "updatedInput": {**tool_input, "answers": answers}}}
    if name == "PermissionRequest":
        if tool in ("AskUserQuestion", "ExitPlanMode"):
            return None  # pertanyaan ditangani PreToolUse; rencana dibaca di terminal
        suggestions = hook.get("permission_suggestions")
        detail = tool_summary(tool, tool_input)
        if tool_input.get("command") and tool_input.get("description"):
            detail = tool + ": " + str(tool_input["command"])
        answer = ask_island(hook, "permission", "Izinkan " + (tool or "tool") + "?", detail[:2000],
                            can_always=bool(suggestions))
        if not answer:
            return None
        if answer.get("decision") == "deny":
            decision = {"behavior": "deny", "message": "Ditolak pengguna lewat Coucou"}
        else:
            decision = {"behavior": "allow"}
            if answer.get("decision") == "always" and isinstance(suggestions, list):
                decision["updatedPermissions"] = suggestions
        return {"hookSpecificOutput": {"hookEventName": "PermissionRequest", "decision": decision}}
    return None


def main():
    try:
        hook = json.loads(sys.stdin.read(1024 * 1024) or "{}")
        if not isinstance(hook, dict):
            return 0
        if "--interactive" in sys.argv[1:]:
            output = interactive(hook)
            if output is not None:
                sys.stdout.write(json.dumps(output, ensure_ascii=False))
            return 0
        event = build(hook)
        if event is None:
            return 0
        from bridge_client import request
        cwd = str(hook.get("cwd") or "")
        request("POST", "/event", {
            "event": event[0], "agent": "claude", "message": event[1],
            "tool_name": event[2], "kind": event[3],
            "session_id": str(hook.get("session_id") or ""),
            "project": os.path.basename(cwd.rstrip("/")) or cwd,
        }, timeout=TIMEOUT)
    except Exception:
        pass  # Coucou tidak jalan / token belum ada: diam saja.
    return 0


if __name__ == "__main__":
    sys.exit(main())
