#!/usr/bin/env python3
import http.server
import json
import os
import sys
import sqlite3
import time
import threading

PORT = 4848
last_decision = None
NOTES_FILE = os.path.expanduser("~/.config/qbot_notes.json")
DB_PATH = os.path.expanduser("~/.hermes/state.db")

def load_notes():
    if os.path.exists(NOTES_FILE):
        try:
            with open(NOTES_FILE, 'r', encoding='utf-8') as f:
                return json.load(f)
        except Exception:
            return []
    return []

def save_notes(notes):
    os.makedirs(os.path.dirname(NOTES_FILE), exist_ok=True)
    with open(NOTES_FILE, 'w', encoding='utf-8') as f:
        json.dump(notes, f, ensure_ascii=False, indent=2)

def emit(event_dict):
    try:
        print(json.dumps(event_dict), flush=True)
    except Exception:
        pass

class HubHandler(http.server.BaseHTTPRequestHandler):
    def log_message(self, format, *args):
        pass

    def do_OPTIONS(self):
        self.send_response(200)
        self.send_header('Access-Control-Allow-Origin', '*')
        self.send_header('Access-Control-Allow-Methods', 'POST, GET, OPTIONS')
        self.send_header('Access-Control-Allow-Headers', 'Content-Type')
        self.end_headers()

    def do_POST(self):
        global last_decision
        try:
            content_length = int(self.headers.get('Content-Length', 0))
            post_data = self.rfile.read(content_length) if content_length > 0 else b'{}'
            data = json.loads(post_data.decode('utf-8'))
            
            if self.path == '/event':
                event_name = data.get("hook_event_name") or data.get("event")
                msg = {
                    "event": event_name,
                    "tool_name": data.get("tool_name", ""),
                    "message": data.get("message", "")
                }
                emit(msg)
                self.send_response(200)
                self.send_header('Content-Type', 'application/json')
                self.end_headers()
                self.wfile.write(b'{"status":"ok"}')
                return

            if self.path == '/notes/add':
                text = data.get("text", "").strip()
                if text:
                    notes = load_notes()
                    note_id = int(time.time() * 1000)
                    timestamp = time.strftime("%H:%M")
                    notes.insert(0, {"id": note_id, "text": text, "time": timestamp})
                    save_notes(notes)
                    emit({"event": "NotesUpdated", "notes": notes})
                self.send_response(200)
                self.send_header('Content-Type', 'application/json')
                self.end_headers()
                self.wfile.write(b'{"status":"ok"}')
                return

            if self.path == '/notes/delete':
                note_id = data.get("id")
                notes = load_notes()
                notes = [n for n in notes if n.get("id") != note_id]
                save_notes(notes)
                emit({"event": "NotesUpdated", "notes": notes})
                self.send_response(200)
                self.send_header('Content-Type', 'application/json')
                self.end_headers()
                self.wfile.write(b'{"status":"ok"}')
                return

            if self.path == '/decision':
                last_decision = data.get("decision")
                self.send_response(200)
                self.send_header('Content-Type', 'application/json')
                self.end_headers()
                self.wfile.write(b'{"status":"ok"}')
                return

        except Exception as e:
            try:
                self.send_response(500)
                self.send_header('Content-Type', 'application/json')
                self.end_headers()
                self.wfile.write(json.dumps({"status": "err", "error": str(e)}).encode())
            except Exception:
                pass

    def do_GET(self):
        global last_decision
        if self.path == '/decision':
            resp = {"decision": last_decision}
            last_decision = None
            self.send_response(200)
            self.send_header('Content-Type', 'application/json')
            self.end_headers()
            self.wfile.write(json.dumps(resp).encode())
            return

        if self.path == '/notes':
            notes = load_notes()
            self.send_response(200)
            self.send_header('Content-Type', 'application/json')
            self.end_headers()
            self.wfile.write(json.dumps(notes).encode())
            return

        if self.path == '/usage':
            db_path = os.path.expanduser("~/.9router/db/data.sqlite")
            res = {"requests": 0, "cost": 0.0, "tokens": 0}
            if os.path.exists(db_path):
                try:
                    conn = sqlite3.connect(db_path)
                    cur = conn.cursor()
                    cur.execute("SELECT SUM(requests), SUM(totalCost), SUM(totalTokens) FROM usageDaily;")
                    row = cur.fetchone()
                    if row:
                        res["requests"] = row[0] or 0
                        res["cost"] = round(row[1] or 0.0, 2)
                        res["tokens"] = row[2] or 0
                    conn.close()
                except Exception:
                    pass
            self.send_response(200)
            self.send_header('Content-Type', 'application/json')
            self.end_headers()
            self.wfile.write(json.dumps(res).encode())
            return

        self.send_response(404)
        self.end_headers()

def watch_hermes_thread():
    if not os.path.exists(DB_PATH):
        return

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

    while True:
        try:
            time.sleep(0.3)
            conn = sqlite3.connect(f"file:{DB_PATH}?mode=ro", uri=True)
            cur = conn.cursor()
            cur.execute("""
                SELECT id, role, content, tool_name, tool_calls 
                FROM messages 
                WHERE id > ? 
                ORDER BY id ASC;
            """, (last_id,))
            rows = cur.fetchall()
            conn.close()

            for msg_id, role, content, tool_name, tool_calls in rows:
                last_id = msg_id
                if role == "tool":
                    emit({"event": "PostToolUse", "tool_name": tool_name or "Tool"})
                elif role == "assistant":
                    if tool_calls and tool_calls != "[]":
                        try:
                            calls = json.loads(tool_calls)
                            func_name = calls[0].get("function", {}).get("name", "Tool")
                            emit({"event": "PreToolUse", "tool_name": func_name})
                        except Exception:
                            emit({"event": "PreToolUse", "tool_name": "Running command"})
                    elif content and content.strip():
                        # Selesai menjawab
                        clean_text = content.strip().replace("\n", " ")
                        if len(clean_text) > 75:
                            clean_text = clean_text[:72] + "..."
                        emit({"event": "StopSuccess", "message": clean_text})
        except Exception:
            pass

if __name__ == '__main__':
    # Start DB Watcher thread
    t = threading.Thread(target=watch_hermes_thread, daemon=True)
    t.start()

    # Start HTTP Server
    http.server.ThreadingHTTPServer.allow_reuse_address = True
    server = http.server.ThreadingHTTPServer(('127.0.0.1', PORT), HubHandler)
    server.serve_forever()
