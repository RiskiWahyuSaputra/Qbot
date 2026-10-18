#!/usr/bin/env python3
"""Pantau SQLite Hermes dan teruskan event ke bridge Coucou.

Menggunakan bridge_client (token lokal) sehingga tidak lagi ditolak 401.
Kiriman bersifat at-least-once: baris hanya dianggap terkirim setelah bridge
mengembalikan status ok, sehingga event tidak hilang saat bridge restart.
"""
import json
import os
import sqlite3
import sys
import time

from bridge_client import BridgeClientError, request

DB_PATH = os.path.expanduser("~/.hermes/state.db")


def send_event(evt, payload):
    data = {"event": evt, **payload}
    try:
        result = request("POST", "/event", data)
        return bool(isinstance(result, dict) and result.get("ok"))
    except (BridgeClientError, ValueError):
        return False
    except OSError:
        return False


def watch_hermes():
    # Hermes bisa dijalankan setelah Coucou: tunggu DB muncul, jangan keluar
    # (proses ini tidak di-restart oleh QML).
    while not os.path.exists(DB_PATH):
        time.sleep(5)

    # Inisialisasi last_id dengan id pesan terakhir
    last_id = 0
    try:
        conn = sqlite3.connect(f"file:{DB_PATH}?mode=ro", uri=True)
        cur = conn.cursor()
        cur.execute("SELECT MAX(id) FROM messages;")
        row = cur.fetchone()
        if row and row[0]:
            last_id = row[0]
        conn.close()
    except Exception:
        pass

    backoff = 0.25
    while True:
        try:
            time.sleep(0.25)
            conn = sqlite3.connect(f"file:{DB_PATH}?mode=ro", uri=True)
            cur = conn.cursor()
            cur.execute("""
                SELECT id, role, content, tool_name, tool_calls, finish_reason 
                FROM messages 
                WHERE id > ? 
                ORDER BY id ASC;
            """, (last_id,))
            rows = cur.fetchall()
            conn.close()

            for msg_id, role, content, tool_name, tool_calls, finish_reason in rows:
                event = build_event(role, content, tool_name, tool_calls, finish_reason)
                if event is None:
                    last_id = msg_id
                    continue
                if not send_event(event[0], event[1]):
                    # Bridge belum siap: jangan tandai terkirim, coba lagi.
                    raise ConnectionError("bridge unreachable")
                last_id = msg_id
                backoff = 0.25
        except ConnectionError:
            # Majukan sedikit agar tidak membanjiri saat bridge mati.
            time.sleep(backoff)
            backoff = min(backoff * 2, 2.0)
        except Exception:
            time.sleep(1.0)


def build_event(role, content, tool_name, tool_calls, finish_reason):
    if role == "user":
        # Abaikan system/background notification yang otomatis
        is_system_notice = content and ("[IMPORTANT: Background process" in content
                                        or "[CONTEXT COMPACTION" in content)
        if is_system_notice:
            return None
        clean_prompt = content.strip().replace("\n", " ") if content else "Task baru diterima"
        if len(clean_prompt) > 40:
            clean_prompt = clean_prompt[:37] + "..."
        return ("TaskStarted", {"message": clean_prompt})
    if role == "tool":
        return ("PostToolUse", {"tool_name": tool_name or "Tool"})
    if role == "assistant" and tool_calls:
        try:
            first = tool_calls[0]
            if isinstance(first, str):
                first = json.loads(first)
            fn = (first.get("function") or {})
            args_str = fn.get("arguments", "")
            name = fn.get("name") or "Tool"
            if "approval" in str(args_str).lower() or "confirm" in str(args_str).lower():
                # Info/demo saja: request approval asli datang dari WebSocket Hermes.
                return ("PermissionRequest",
                        {"tool_name": name, "message": f"Konfirmasi eksekusi: {name}"})
            return ("PreToolUse", {"tool_name": name})
        except Exception:
            return ("PreToolUse", {"tool_name": "Executing tool"})
    if finish_reason == "stop" and content and content.strip():
        clean_text = content.strip().replace("\n", " ")
        if len(clean_text) > 60:
            clean_text = clean_text[:57] + "..."
        return ("StopSuccess", {"message": clean_text})
    return None


if __name__ == "__main__":
    sys.exit(watch_hermes())
