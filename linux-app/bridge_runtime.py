"""Transport, authorization and side effects for the Coucou bridge.

Stdout is exclusively NDJSON; the websocket receiver never waits on a decision.
Only a positively acknowledged, correlated JSON-RPC reply can confirm a decision.
"""
import asyncio
from concurrent.futures import Future, TimeoutError as FutureTimeout
from contextlib import suppress
import http.server
import json
import os
from pathlib import Path
import re
import secrets
import select
import shutil
import socket
import stat
import subprocess
import sys
import tempfile
import threading
import time
from urllib.parse import urlsplit, quote
import uuid

from bridge_client import MAX_BODY, runtime_directory
from dev_servers import DevServerManager
from interview import InterviewAssistant

IO_TIMEOUT = 5
RPC_TIMEOUT = 8
EVENTS = {"TaskStarted", "PreToolUse", "PostToolUse", "StopSuccess", "PermissionRequest"}
# Status sesi agent coding (claude_hook.py / plugin OpenCode); hanya informatif.
AGENT_EVENTS = {"AgentSessionStart", "AgentPrompt", "AgentToolStart", "AgentToolDone",
                "AgentWaiting", "AgentStop", "AgentSessionEnd"}
AGENTS = {"claude", "opencode"}
MAX_AGENT_REQUESTS = 6      # long-poll memakai slot thread HTTP (16 total)
MAX_REQUEST_WAIT = 600


def _text(value, limit):
    return str(value or "")[:limit] if isinstance(value, (str, int, float)) else ""


def normalize_questions(raw):
    """[{question, header, options:[{label, description}], multiSelect, custom}] (dibatasi)."""
    if not isinstance(raw, list) or not 1 <= len(raw) <= 4:
        raise ValueError("questions must be a list of 1-4 items")
    out = []
    for item in raw:
        if not isinstance(item, dict) or not _text(item.get("question"), 1000).strip():
            raise ValueError("Each question needs question text")
        options = item.get("options") or []
        if not isinstance(options, list) or len(options) > 12:
            raise ValueError("options must be a list of at most 12 items")
        norm = []
        for option in options:
            if isinstance(option, str):
                option = {"label": option}
            if not isinstance(option, dict) or not _text(option.get("label"), 200).strip():
                raise ValueError("Each option needs a label")
            norm.append({"label": _text(option["label"], 200), "description": _text(option.get("description"), 300)})
        out.append({"id": _text(item.get("id"), 100), "question": _text(item["question"], 1000),
                    "header": _text(item.get("header"), 60), "options": norm,
                    "multiSelect": bool(item.get("multiSelect")), "custom": item.get("custom", True) is not False})
    return out


def validate_answer(kind, answer, questions):
    """permission: {decision: allow|always|deny|terminal}; question: {answers: [[label]]} | {decision: terminal}."""
    if not isinstance(answer, dict):
        raise ValueError("answer must be an object")
    decision = answer.get("decision")
    if decision == "terminal":
        return {"decision": "terminal"}
    if kind == "permission":
        if decision not in ("allow", "always", "deny"):
            raise ValueError("decision must be allow, always, deny or terminal")
        return {"decision": decision}
    answers = answer.get("answers")
    if not isinstance(answers, list) or len(answers) != len(questions):
        raise ValueError("answers must have one entry per question")
    clean = []
    for picked, question in zip(answers, questions):
        if not isinstance(picked, list) or not 1 <= len(picked) <= 12 or not all(isinstance(x, str) and x.strip() for x in picked):
            raise ValueError("Each answer must be a nonempty list of labels")
        if not question["multiSelect"] and len(picked) != 1:
            raise ValueError("Single-select question needs exactly one answer")
        labels = {o["label"] for o in question["options"]}
        if not question["custom"] and any(x not in labels for x in picked):
            raise ValueError("Answer is not one of the options")
        clean.append([x[:2000] for x in picked])
    return {"answers": clean}


def diagnostic(message, exc=None):
    # Exception strings may include the websocket URL (and its secret token).
    suffix = " (" + type(exc).__name__ + ")" if exc else ""
    print("bridge: " + message + suffix, file=sys.stderr, flush=True)


def valid_id(value):
    return isinstance(value, str) and bool(value.strip()) and len(value) <= 512


def decode_json(raw):
    def invalid(_):
        raise ValueError("Non-finite JSON number")
    return json.loads(raw, parse_constant=invalid)


class EventEmitter:
    def __init__(self, stream=None, stop=None):
        self.stream = sys.stdout if stream is None else stream
        self.stop = stop
        self.lock = threading.Lock()

    def emit(self, event):
        with self.lock:
            try:
                self.stream.write(json.dumps(event, ensure_ascii=True, allow_nan=False,
                                             separators=(",", ":")) + "\n")
                self.stream.flush()
            except (BrokenPipeError, OSError, ValueError):
                if self.stop is not None:
                    self.stop.set()
                raise


class TokenFile:
    """Publish only after HTTP bind. flock also isolates different-port instances."""
    def __init__(self):
        self.path = None
        self.lock_fd = None
        self.identity = None
        self.token = secrets.token_hex(32)

    def create(self):
        import fcntl
        directory = runtime_directory()
        directory.mkdir(mode=0o700, exist_ok=True)
        info = directory.lstat()
        if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o077:
            raise ValueError("Unsafe bridge runtime directory")
        self.path = directory / "bridge.token"
        fd = os.open(directory / "bridge.lock", os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW | os.O_NONBLOCK, 0o600)
        try:
            info = os.fstat(fd)
            if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o077:
                raise ValueError("Unsafe bridge lock file")
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            self.lock_fd = fd
        except BaseException:
            os.close(fd)
            raise
        temp_path = None
        try:
            fd, temp_path = tempfile.mkstemp(prefix=".token-", dir=directory)
            with os.fdopen(fd, "w", encoding="ascii") as stream:
                stream.write(self.token + "\n")
                stream.flush()
                os.fsync(stream.fileno())
                info = os.fstat(stream.fileno())
            os.replace(temp_path, self.path)
            self.identity = (info.st_dev, info.st_ino)
        except BaseException:
            if temp_path:
                with suppress(OSError):
                    os.unlink(temp_path)
            self.close()
            raise

    def close(self):
        if self.identity is not None:
            with suppress(OSError):
                info = self.path.lstat()
                if (info.st_dev, info.st_ino) == self.identity:
                    self.path.unlink()
            self.identity = None
        if self.lock_fd is not None:
            os.close(self.lock_fd)
            self.lock_fd = None


class NotesStore:
    def __init__(self, path=None):
        self.path = Path(path) if path is not None else Path.home() / ".config/qbot_notes.json"
        self.lock = threading.RLock()

    @staticmethod
    def validate(notes):
        if not isinstance(notes, list) or len(notes) > 1000:
            raise ValueError("notes must be a list of at most 1000 notes")
        ids = set()
        for note in notes:
            if not isinstance(note, dict) or not isinstance(note.get("text"), str) or len(note["text"]) > 16384:
                raise ValueError("Each note requires a text string (at most 16384 characters)")
            identity = note.get("id")
            if isinstance(identity, bool) or not isinstance(identity, (int, str)) or identity == "":
                raise ValueError("Each note requires a string or integer id")
            if identity in ids:
                raise ValueError("Duplicate note id")
            ids.add(identity)
            if "time" in note and (not isinstance(note["time"], str) or len(note["time"]) > 128):
                raise ValueError("Invalid note time")
        if len(json.dumps(notes, allow_nan=False).encode()) > MAX_BODY:
            raise ValueError("Notes too large")
        return notes

    def load(self):
        with self.lock:
            try:
                fd = os.open(self.path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
                with os.fdopen(fd, "r", encoding="utf-8") as stream:
                    info = os.fstat(stream.fileno())
                    if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid():
                        raise ValueError("Notes must be an owned regular file")
                    raw = stream.read(MAX_BODY + 1)
                if len(raw.encode()) > MAX_BODY:
                    raise ValueError("Notes too large")
                return self.validate(decode_json(raw))
            except FileNotFoundError:
                return []

    def save(self, notes):
        self.validate(notes)
        with self.lock:
            self.path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
            fd, temp_path = tempfile.mkstemp(prefix=".qbot-notes-", dir=self.path.parent)
            try:
                with os.fdopen(fd, "w", encoding="utf-8") as stream:
                    json.dump(notes, stream, ensure_ascii=True, allow_nan=False)
                    stream.flush()
                    os.fsync(stream.fileno())
                os.replace(temp_path, self.path)
            finally:
                with suppress(FileNotFoundError):
                    os.unlink(temp_path)


class Launcher:
    """No command strings, shell interpolation, or inherited stdout/stdin."""
    @staticmethod
    def run(argv, timeout=5, capture=False, input_data=None):
        kwargs = {"shell": False, "stdout": subprocess.PIPE if capture else subprocess.DEVNULL,
                  "stderr": subprocess.DEVNULL, "timeout": timeout, "text": True}
        if input_data is None:
            kwargs["stdin"] = subprocess.DEVNULL
        else:
            kwargs["input"] = input_data
        result = subprocess.run(argv, **kwargs)
        if result.returncode:
            raise ValueError("Command failed or was cancelled")
        return result.stdout.strip() if capture else "Command completed"

    @staticmethod
    def spawn(argv):
        child = subprocess.Popen(argv, shell=False, stdin=subprocess.DEVNULL,
                                 stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                                 start_new_session=True)
        threading.Thread(target=child.wait, daemon=True).start()
        return "Application launched (startup not confirmed)"

    def launch(self, command):
        if "cmd" in command:
            raise ValueError("Arbitrary commands are not supported; use an allowlisted name")
        name = command.get("name")
        if name == "editor":
            return self.spawn(["code"])
        if name == "terminal":
            terminal = next((p for p in ("kitty", "konsole", "gnome-terminal", "x-terminal-emulator") if shutil.which(p)), None)
            if not terminal:
                raise ValueError("No supported terminal installed")
            return self.spawn([terminal])
        if name == "files":
            return self.spawn(["xdg-open", str(Path.home())])
        if name in ("volume_up", "volume_down", "volume_mute"):
            args = {"volume_up": ["set-sink-volume", "@DEFAULT_SINK@", "+5%"],
                    "volume_down": ["set-sink-volume", "@DEFAULT_SINK@", "-5%"],
                    "volume_mute": ["set-sink-mute", "@DEFAULT_SINK@", "toggle"]}
            return self.run(["pactl"] + args[name])
        if name == "open_url":
            url = command.get("url")
            if not isinstance(url, str) or len(url) > 8192 or any(ord(c) <= 32 or ord(c) == 127 for c in url):
                raise ValueError("Invalid URL")
            parsed = urlsplit(url)
            if parsed.scheme not in ("http", "https") or not parsed.hostname or parsed.username or parsed.password:
                raise ValueError("Only http/https URLs without credentials are supported")
            _ = parsed.port  # also reject malformed port numbers
            return self.spawn(["xdg-open", url])
        if name == "open_project":
            path = command.get("path")
            if not isinstance(path, str) or "\0" in path or not os.path.isabs(path) or not os.path.isdir(path):
                raise ValueError("Project path must be an absolute existing directory")
            return self.spawn(["code", "--", os.path.realpath(path)])
        if name == "screenshot":
            if not shutil.which("slurp") or not shutil.which("grim"):
                raise ValueError("Screenshot requires slurp and grim")
            geometry = self.run(["slurp"], timeout=20, capture=True)
            if not re.fullmatch(r"-?\d+,-?\d+ [1-9]\d*,[1-9]\d*", geometry):
                raise ValueError("Screenshot cancelled or invalid selection")
            directory = Path.home() / "Pictures"
            directory.mkdir(parents=True, exist_ok=True)
            fd, path = tempfile.mkstemp(prefix="Coucou-", suffix=".png", dir=directory)
            os.close(fd)
            try:
                self.run(["grim", "-g", geometry, path])
            except BaseException:
                with suppress(OSError):
                    os.unlink(path)
                raise
            return "Screenshot saved: " + path
        raise ValueError("Unknown launch name")

    def run_in_terminal(self, text):
        """Open a terminal that runs a command note the user saved and clicked.

        The text comes from the owned notes file (never from the command
        payload) and is one argv element for `sh -c`, so no extra quoting.
        """
        if not isinstance(text, str) or not text.strip() or "\0" in text:
            raise ValueError("Command note is empty")
        script = text.strip()
        holds = {"kitty": ["kitty", "--hold", "sh", "-c", script],
                 "konsole": ["konsole", "--hold", "-e", "sh", "-c", script],
                 "foot": ["foot", "--hold", "sh", "-c", script],
                 "alacritty": ["alacritty", "--hold", "-e", "sh", "-c", script]}
        terminal = next((name for name in holds if shutil.which(name)), None)
        if not terminal:
            raise ValueError("No supported terminal installed")
        self.spawn(holds[terminal])
        return "Command dibuka di " + terminal

    def media(self, name):
        if name not in ("play-pause", "next", "previous"):
            raise ValueError("Unknown media action")
        return self.run(["playerctl", name])


class BridgeRuntime:
    def __init__(self, emitter=None, notes=None, launcher=None, rpc_timeout=RPC_TIMEOUT,
                 dev_projects=None, dev_root=None):
        self.stop = threading.Event()
        self.emitter = emitter or EventEmitter(stop=self.stop)
        self.notes = notes or NotesStore()
        self.launcher = launcher or Launcher()
        self.rpc_timeout = rpc_timeout
        self.dev = DevServerManager(
            dev_projects or [], dev_root or (Path.home() / "Projects/project-web"),
            emit=self.emit, directory=runtime_directory(), stop=self.stop)
        self.interview = InterviewAssistant(emit=self.emit)
        self.lock = threading.RLock()
        self.pending = {}  # (session_id, request_id) -> ready/submitting/uncertain
        self.resolved = set()  # do not resurrect replayed resolved requests
        self.calls = {}  # rpc id -> Future; never reuse ids across connections
        self.ws = None
        self.loop = None
        self.status = None
        # Permintaan izin/pertanyaan agent yang menunggu jawaban dari island.
        # id -> {"info", "event", "answer", "status", ("hermes": (sid, rid, qids))}
        self.agent_requests = {}

    def emit(self, event):
        self.emitter.emit(event)

    def set_status(self, connected, message):
        with self.lock:
            value = (connected, message)
            if self.status != value:
                self.status = value
                self.emit({"event": "BridgeStatus", "connected": connected, "message": message})

    def connected(self, ws, loop):
        with self.lock:
            self.ws, self.loop = ws, loop
            self.set_status(True, "Connected to Hermes")

    def disconnected(self):
        with self.lock:
            self.ws = self.loop = None
            self.pending.clear()
            for request_id in [k for k, v in self.agent_requests.items() if "hermes" in v]:
                self.close_request(request_id, "cancelled")
            for future in self.calls.values():
                if not future.done():
                    future.set_exception(ConnectionError("Hermes disconnected before acknowledgement"))
            self.calls.clear()
            self.set_status(False, "Hermes disconnected; pending approvals are no longer actionable")

    def handle_ws(self, msg):
        if not isinstance(msg, dict):
            return
        with self.lock:
            rpc_id = msg.get("id")
            if isinstance(rpc_id, str) and ("result" in msg or "error" in msg):
                future = self.calls.get(rpc_id)
                if future is not None and not future.done():
                    future.set_result(msg)
                return
            params = msg.get("params", {})
            if not isinstance(params, dict):
                return
            event = params.get("type") or msg.get("method")
            payload = params.get("payload", params)
            if not isinstance(payload, dict):
                return
            sid, rid = params.get("session_id"), payload.get("request_id")
            if event in ("approval.request", "approval.respond"):
                if not valid_id(sid) or not valid_id(rid):
                    diagnostic("Ignoring approval with missing/invalid identity")
                    return
                key = (sid, rid)
                if event == "approval.request":
                    if self.ws is None or key in self.pending or key in self.resolved:
                        return
                    self.pending[key] = "ready"
                    self.emit({"event": "PermissionRequest", "session_id": sid, "request_id": rid,
                               "message": str(payload.get("command") or payload.get("description") or "Approval requested"),
                               "tool_name": str(payload.get("tool_name") or "terminal"), "actionable": True})
                elif key in self.pending:
                    del self.pending[key]
                    self.resolved.add(key)
                    self.emit({"event": "ApprovalResolved", "session_id": sid, "request_id": rid})
            elif event == "clarify.request":
                self.hermes_clarify(sid, payload)
            elif event == "clarify.expire":
                self.close_request("hermes:" + str(payload.get("request_id") or ""), "expired")
            elif event in EVENTS - {"PermissionRequest"}:
                self.emit({**payload, "event": event})

    # ---- Permintaan interaktif (izin / pertanyaan) dari agent ----

    def _register_request(self, info, extra=None):
        with self.lock:
            if info["request_id"] in self.agent_requests:
                raise ValueError("Duplicate request id")
            if len(self.agent_requests) >= MAX_AGENT_REQUESTS:
                raise ValueError("Too many pending requests")
            entry = {"info": info, "event": threading.Event(), "answer": None, "status": "pending", **(extra or {})}
            self.agent_requests[info["request_id"]] = entry
        self.emit({"event": "AgentRequest", **info})
        return entry

    def close_request(self, request_id, reason, answer=None):
        """Selesaikan request (answered/cancelled/timeout/expired) dan tutup kartunya di island."""
        with self.lock:
            entry = self.agent_requests.pop(request_id, None)
            if entry is None:
                return False
            entry["status"], entry["answer"] = reason, answer
            entry["event"].set()
        self.emit({"event": "AgentRequestClosed", "request_id": request_id, "reason": reason})
        return True

    def open_request(self, data, still_connected=lambda: True):
        """HTTP long-poll dari hook/plugin: tampilkan, lalu tunggu jawaban island."""
        agent = data.get("agent")
        if agent not in AGENTS:
            raise ValueError("agent must be one of " + ", ".join(sorted(AGENTS)))
        kind = data.get("kind")
        if kind not in ("permission", "question"):
            raise ValueError("kind must be permission or question")
        local_id = data.get("request_id")
        if not valid_id(local_id) or len(local_id) > 200:
            raise ValueError("request_id required")
        info = {"request_id": agent + ":" + local_id, "agent": agent, "kind": kind,
                "session_id": _text(data.get("session_id"), 200), "project": _text(data.get("project"), 200),
                "title": _text(data.get("title"), 300), "detail": _text(data.get("detail"), 2000),
                "can_always": bool(data.get("can_always")),
                "questions": normalize_questions(data.get("questions")) if kind == "question" else []}
        wait = data.get("timeout", 120)
        if isinstance(wait, bool) or not isinstance(wait, (int, float)) or not 1 <= wait <= MAX_REQUEST_WAIT:
            raise ValueError("timeout must be 1-600 seconds")
        entry = self._register_request(info)
        deadline = time.monotonic() + wait
        while not entry["event"].wait(0.5):
            if time.monotonic() >= deadline:
                self.close_request(info["request_id"], "timeout")
                break
            if self.stop.is_set() or not still_connected():
                self.close_request(info["request_id"], "cancelled")
                break
        return {"ok": True, "status": entry["status"], "answer": entry["answer"]}

    def hermes_clarify(self, sid, payload):
        rid = payload.get("request_id")
        if not valid_id(sid) or not valid_id(rid):
            diagnostic("Ignoring clarify with missing/invalid identity")
            return
        if isinstance(payload.get("questions"), list):
            raw = [{"id": q.get("qid"), "question": q.get("question"), "options": q.get("choices") or [],
                    "multiSelect": q.get("multi_select")} for q in payload["questions"] if isinstance(q, dict)]
        else:
            raw = [{"question": payload.get("question"), "options": payload.get("choices") or [],
                    "multiSelect": payload.get("multi_select")}]
        try:
            questions = normalize_questions(raw)
            info = {"request_id": "hermes:" + rid, "agent": "hermes", "kind": "question", "session_id": sid,
                    "project": "", "title": "Hermes bertanya", "detail": "", "can_always": False,
                    "questions": questions}
            self._register_request(info, {"hermes": (sid, rid, [q["id"] for q in questions])})
        except ValueError as exc:
            diagnostic("Ignoring clarify request: " + str(exc))

    def _hermes_rpc(self, method, params):
        rpc_id, future = uuid.uuid4().hex, Future()
        with self.lock:
            if self.ws is None or self.loop is None:
                raise ValueError("Hermes is disconnected")
            self.calls[rpc_id] = future
            ws, loop = self.ws, self.loop
        try:
            message = json.dumps({"jsonrpc": "2.0", "id": rpc_id, "method": method, "params": params})
            asyncio.run_coroutine_threadsafe(ws.send(message), loop).result(timeout=self.rpc_timeout)
            reply = future.result(timeout=self.rpc_timeout)
        except (FutureTimeout, ConnectionError, OSError) as exc:
            raise ValueError("Hermes tidak membalas jawaban") from exc
        finally:
            with self.lock:
                self.calls.pop(rpc_id, None)
        if not self.acknowledged(reply):
            raise ValueError("Hermes menolak jawaban (mungkin sudah kedaluwarsa)")

    def answer_request(self, command):
        request_id = command.get("request_id")
        with self.lock:
            entry = self.agent_requests.get(request_id) if isinstance(request_id, str) else None
        if entry is None:
            raise ValueError("Permintaan sudah tidak berlaku")
        info = entry["info"]
        answer = validate_answer(info["kind"], command.get("answer"), info["questions"])
        if "hermes" in entry and answer.get("decision") != "terminal":
            sid, rid, qids = entry["hermes"]
            for qid, picked, question in zip(qids, answer["answers"], info["questions"]):
                params = {"session_id": sid, "request_id": rid,
                          "answer": json.dumps(picked, ensure_ascii=False) if question["multiSelect"] else picked[0]}
                if len(qids) > 1 and qid:
                    params["question_id"] = qid
                self._hermes_rpc("clarify.respond", params)
        self.close_request(request_id, "answered", answer)
        return "Jawaban terkirim"

    def publish_event(self, data):
        event = data.get("event") or data.get("hook_event_name")
        if not isinstance(event, str) or event not in EVENTS | AGENT_EVENTS:
            raise ValueError("Unknown event")
        output = {"event": event}
        names = ("message", "tool_name", "session_id", "request_id")
        if event in AGENT_EVENTS:
            if data.get("agent") not in AGENTS:
                raise ValueError("agent must be one of " + ", ".join(sorted(AGENTS)))
            output["agent"] = data["agent"]
            # kind: "permission" | "input" (AgentWaiting), "error" (AgentStop)
            names = ("message", "tool_name", "session_id", "project", "kind")
        for name in names:
            value = data.get(name, "")
            if not isinstance(value, str):
                raise ValueError(name + " must be a string")
            output[name] = value[:300]
        if event == "PermissionRequest":
            output["actionable"] = False
        self.emit(output)
        return {"ok": True, "status": "ok"}

    @staticmethod
    def acknowledged(reply):
        if reply.get("jsonrpc") != "2.0" or "error" in reply or "result" not in reply:
            return False
        result = reply["result"]
        # An opaque/empty result is NOT proof of approval. Accept only explicit
        # positive ACKs; server errors and negative fields always win.
        if result is True:
            return True
        if not isinstance(result, dict) or result.get("error") or any(
                result.get(key) is False for key in ("ok", "success", "accepted")):
            return False
        if "status" in result and result["status"] not in ("ok", "success", "accepted"):
            return False
        return any(result.get(key) is True for key in ("ok", "success", "accepted")) or result.get("status") in ("ok", "success", "accepted")

    def decision(self, command):
        sid, rid, choice = command.get("session_id"), command.get("request_id"), command.get("decision")
        if not valid_id(command.get("id")) or not valid_id(sid) or not valid_id(rid):
            return False, "Command, session and request IDs are required"
        if choice not in ("allow", "deny"):
            return False, "Decision must be allow or deny"
        key = (sid, rid)
        rpc_id, future = uuid.uuid4().hex, Future()
        with self.lock:
            if key not in self.pending:
                return False, "Unknown or stale approval request"
            if self.pending[key] != "ready":
                return False, "Decision already submitted; awaiting authoritative resolution"
            if self.ws is None or self.loop is None:
                return False, "Hermes is disconnected"
            self.pending[key] = "submitting"
            self.calls[rpc_id] = future
            ws, loop = self.ws, self.loop

        async def send():
            with self.lock:
                if self.ws is not ws or self.pending.get(key) != "submitting":
                    raise ConnectionError("Approval became stale before submission")
            await ws.send(json.dumps({"jsonrpc": "2.0", "id": rpc_id, "method": "approval.respond",
                                      "params": {"session_id": sid, "request_id": rid,
                                                 "choice": "approve" if choice == "allow" else "deny"}}))

        def send_done(sent):
            try:
                sent.result()
            except BaseException:
                with self.lock:
                    if not future.done():
                        future.set_exception(ConnectionError("Unable to send decision"))

        ok, message, retryable = False, "Decision not acknowledged by Hermes", False
        coroutine = send()
        try:
            try:
                sent = asyncio.run_coroutine_threadsafe(coroutine, loop)
            except BaseException:
                coroutine.close()
                raise
            sent.add_done_callback(send_done)
            reply = future.result(timeout=self.rpc_timeout)
            ok = self.acknowledged(reply)
            if ok:
                message = "Hermes acknowledged decision"
            elif reply.get("jsonrpc") == "2.0" and isinstance(reply.get("error"), dict):
                message, retryable = "Hermes rejected decision (JSON-RPC error)", True
            else:
                message = "Hermes did not positively acknowledge decision; outcome unknown"
        except FutureTimeout:
            message = "Timed out waiting for Hermes acknowledgement; outcome unknown"
            if "sent" in locals():
                sent.cancel()
        except Exception as exc:
            diagnostic("Decision transport failed", exc)
            message = "Hermes disconnected or send failed before acknowledgement; outcome unknown"
        finally:
            with self.lock:
                self.calls.pop(rpc_id, None)
                if ok:
                    self.pending.pop(key, None)
                    self.resolved.add(key)
                elif key in self.pending:
                    self.pending[key] = "ready" if retryable else "uncertain"
        return ok, message

    def command(self, data):
        if not isinstance(data, dict):
            data = {}
        action, identity = data.get("action"), data.get("id")
        result = {"event": "DecisionResult" if action == "decision" else "ActionResult",
                  "id": identity if isinstance(identity, str) else "", "ok": False, "message": ""}
        if action == "decision":
            result.update({key: data.get(key) if isinstance(data.get(key), str) else ""
                           for key in ("session_id", "request_id")})
        try:
            if not valid_id(identity):
                raise ValueError("A nonempty string command id is required")
            if action == "decision":
                result["ok"], result["message"] = self.decision(data)
            else:
                if action == "launch":
                    message = self.launcher.launch(data)
                elif action == "media":
                    message = self.launcher.media(data.get("name"))
                elif action == "agent_answer":
                    message = self.answer_request(data)
                elif action == "run_note":
                    message = self.run_note(data.get("note_id"))
                elif action == "notes_save":
                    self.notes.save(data.get("notes"))
                    message = "Notes saved"
                elif action == "dev_start":
                    message = self.dev.start(data.get("project"), data.get("services"))
                elif action == "dev_stop":
                    message = self.dev.stop(data.get("project"), data.get("services"))
                elif action == "dev_status":
                    self.dev.emit_status()
                    message = "Status dev server diperbarui"
                elif action == "interview_start":
                    message = self.interview.start(data.get("source"), data.get("auto"))
                elif action == "interview_stop":
                    message = self.interview.stop()
                elif action == "interview_answer":
                    message = self.interview.answer_now()
                elif action == "interview_auto":
                    message = self.interview.set_auto(data.get("enabled"))
                elif action == "interview_status":
                    self.interview.emit_status()
                    message = "Status interview diperbarui"
                else:
                    raise ValueError("Unknown action")
                result.update(ok=True, message=message)
        except ValueError as exc:
            result["message"] = str(exc)
        except (OSError, subprocess.SubprocessError) as exc:
            diagnostic("Action failed", exc)
            result["message"] = "Action failed: missing dependency, timeout or I/O error"
        except Exception as exc:
            diagnostic("Command failed", exc)
            result["message"] = "Command failed: invalid payload or local runtime error"
        self.emit(result)
        return result

    def run_note(self, note_id):
        if isinstance(note_id, bool) or not isinstance(note_id, (int, str)) or note_id == "":
            raise ValueError("A note id is required")
        # QML menyimpan id sebagai string; catatan lama bisa ber-id integer.
        note = next((n for n in self.notes.load() if str(n.get("id")) == str(note_id)), None)
        if note is None:
            raise ValueError("Catatan tidak ditemukan")
        if note.get("tag") != "cmd":
            raise ValueError("Catatan ini bukan command")
        return self.launcher.run_in_terminal(note["text"])

    def read_stdin(self, stream, parent_driven=False):
        # One worker preserves input/action ordering. ACK receipt runs on the WS
        # thread, not here; bounded operations prevent an indefinitely stuck queue.
        try:
            while not self.stop.is_set():
                line = stream.readline(MAX_BODY + 1)
                if not line:
                    break
                if len(line.encode("utf-8")) > MAX_BODY:
                    self.emit({"event": "ActionResult", "id": "", "ok": False, "message": "Command line too large"})
                    # Oversized stdin is a protocol violation: don't interpret a
                    # trailing fragment as another (potentially privileged) command.
                    break
                try:
                    data = decode_json(line)
                except (ValueError, RecursionError):
                    self.emit({"event": "ActionResult", "id": "", "ok": False, "message": "Invalid JSON command"})
                    continue
                self.command(data)
        except (OSError, UnicodeError) as exc:
            diagnostic("stdin closed", exc)
        finally:
            if parent_driven:
                self.stop.set()


def get_hermes_ws_info():
    """Retain local Hermes process/environment/listening-port discovery."""
    out = subprocess.run(["pgrep", "-f", "hermes_cli.main serve"], capture_output=True, text=True, timeout=2).stdout
    for pid in (int(p) for p in out.split() if p.isdigit()):
        try:
            with open(f"/proc/{pid}/environ", "rb") as stream:
                values = stream.read(1024 * 1024).split(b"\0")
            token = next((v.split(b"=", 1)[1].decode() for v in values if v.startswith(b"HERMES_DASHBOARD_SESSION_TOKEN=")), None)
            if not token:
                continue
            output = subprocess.run(["lsof", "-Pan", "-p", str(pid), "-i"], capture_output=True, text=True, timeout=2).stdout
            match = re.search(r":(\d+)\s+\(LISTEN\)", output)
            if match:
                return pid, int(match.group(1)), token
        except (OSError, UnicodeError, subprocess.SubprocessError) as exc:
            diagnostic("Hermes discovery failed for a process", exc)
    return None


async def hermes_ws_listener(runtime):
    try:
        from websockets.asyncio.client import connect
    except ImportError:
        runtime.set_status(False, "Missing dependency: websockets (asyncio client); HTTP and local actions remain available")
        diagnostic("Install websockets in the bridge Python environment to enable approvals")
        return
    missing = [name for name in ("pgrep", "lsof") if not shutil.which(name)]
    if missing:
        runtime.set_status(False, "Missing Hermes discovery dependencies: " + ", ".join(missing))
        diagnostic("Hermes discovery unavailable; install the missing tools and restart the bridge")
        return
    while not runtime.stop.is_set():
        try:
            info = await asyncio.to_thread(get_hermes_ws_info)
            if not info:
                runtime.set_status(False, "Hermes server not found; waiting for local server")
            else:
                _, port, token = info
                async with connect(f"ws://127.0.0.1:{port}/api/ws?token={quote(token, safe='')}",
                                   open_timeout=5, close_timeout=2, ping_timeout=10, max_size=MAX_BODY) as ws:
                    runtime.connected(ws, asyncio.get_running_loop())
                    async for raw in ws:
                        try:
                            runtime.handle_ws(decode_json(raw))
                        except (ValueError, TypeError, RecursionError) as exc:
                            diagnostic("Ignoring malformed Hermes message", exc)
        except asyncio.CancelledError:
            raise
        except Exception as exc:
            diagnostic("Hermes connection/discovery failed", exc)
            runtime.set_status(False, "Hermes unavailable: connection or discovery failed (check local dependencies)")
        finally:
            if runtime.ws is not None:
                runtime.disconnected()
        if not runtime.stop.is_set():
            await asyncio.sleep(2)


def start_ws_listener_thread(runtime):
    async def supervise():
        task = asyncio.create_task(hermes_ws_listener(runtime))
        try:
            while not runtime.stop.is_set() and not task.done():
                await asyncio.sleep(0.1)
        finally:
            task.cancel()
            with suppress(asyncio.CancelledError):
                await task
    asyncio.run(supervise())


class BridgeHTTPServer(http.server.ThreadingHTTPServer):
    daemon_threads = True
    allow_reuse_address = True

    def __init__(self, address, runtime, read_endpoint):
        self.runtime, self.read_endpoint = runtime, read_endpoint
        self.credentials = TokenFile()
        self.slots = threading.BoundedSemaphore(16)
        # Bind first: a second instance must never replace the live credential.
        super().__init__(address, MochiHandler)
        try:
            self.credentials.create()
        except BaseException:
            self.server_close()
            raise

    def get_request(self):
        connection, address = super().get_request()
        connection.settimeout(IO_TIMEOUT)
        return connection, address

    def process_request(self, request, client_address):
        if not self.slots.acquire(blocking=False):
            self.shutdown_request(request)
            return
        try:
            super().process_request(request, client_address)
        except BaseException:
            self.slots.release()
            raise

    def process_request_thread(self, request, client_address):
        try:
            super().process_request_thread(request, client_address)
        finally:
            self.slots.release()

    def handle_error(self, request, client_address):
        diagnostic("HTTP request failed")

    def server_close(self):
        super().server_close()
        self.credentials.close()


class MochiHandler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def parse_request(self):
        if not super().parse_request():
            return False
        # Reject browser requests even for unknown HTTP verbs.
        if "Origin" in self.headers:
            self.send_json(403, {"ok": False, "message": "Browser origins are not allowed"})
            return False
        return True

    def send_json(self, status, data):
        raw = json.dumps(data, ensure_ascii=True, allow_nan=False, separators=(",", ":")).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(raw)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("Connection", "close")
        self.end_headers()
        self.close_connection = True
        self.wfile.write(raw)

    def authorized(self):
        if "Origin" in self.headers:
            self.send_json(403, {"ok": False, "message": "Browser origins are not allowed"})
            return False
        headers = self.headers.get_all("Authorization", [])
        expected = "Bearer " + self.server.credentials.token
        if len(headers) != 1 or not secrets.compare_digest(headers[0].encode(), expected.encode()):
            self.send_json(401, {"ok": False, "message": "Bridge token required"})
            return False
        return True

    def client_connected(self):
        """False bila klien long-poll sudah menutup koneksi (hook dibunuh/selesai)."""
        try:
            readable, _, _ = select.select([self.connection], [], [], 0)
            return not readable or self.connection.recv(1, socket.MSG_PEEK) != b""
        except (OSError, ValueError):
            return False

    def body(self):
        lengths = self.headers.get_all("Content-Length", [])
        if "Transfer-Encoding" in self.headers or len(lengths) != 1:
            raise ValueError("One Content-Length is required; chunked bodies are unsupported")
        try:
            length = int(lengths[0])
        except ValueError:
            raise ValueError("Invalid Content-Length") from None
        if length < 0 or length > MAX_BODY:
            raise ValueError("Request body too large or invalid length")
        if self.headers.get_content_type() != "application/json":
            raise ValueError("Content-Type must be application/json")
        raw = self.rfile.read(length)
        if len(raw) != length:
            raise ValueError("Incomplete request body")
        data = decode_json(raw)
        if not isinstance(data, dict):
            raise ValueError("JSON body must be an object")
        return data

    def do_GET(self):
        if not self.authorized():
            return
        if self.path not in ("/media", "/sysinfo", "/usage", "/gitstatus", "/projects", "/notes"):
            self.send_json(404, {"ok": False, "message": "Unknown path"})
            return
        try:
            data = self.server.runtime.notes.load() if self.path == "/notes" else self.server.read_endpoint(self.path)
            self.send_json(200, data)
        except Exception as exc:
            diagnostic("Read endpoint failed", exc)
            self.send_json(500, {"ok": False, "message": "Unable to read local data"})

    def do_POST(self):
        if not self.authorized():
            return
        if self.path not in ("/event", "/decision", "/launch", "/media/control", "/notes/save", "/notes/add", "/notes/delete", "/clipboard/copy",
                             "/agent/request", "/agent/request/cancel"):
            self.send_json(404, {"ok": False, "message": "Unknown path"})
            return
        runtime = self.server.runtime
        try:
            data = self.body()
            if self.path == "/event":
                result = runtime.publish_event(data)
            elif self.path == "/agent/request":
                result = runtime.open_request(data, self.client_connected)
            elif self.path == "/agent/request/cancel":
                agent, local_id = data.get("agent"), data.get("request_id")
                if agent not in AGENTS or not valid_id(local_id):
                    raise ValueError("agent and request_id required")
                result = {"ok": True, "closed": runtime.close_request(agent + ":" + local_id, "cancelled")}
            elif self.path in ("/decision", "/launch", "/media/control", "/notes/save"):
                action = {"/decision": "decision", "/launch": "launch", "/media/control": "media", "/notes/save": "notes_save"}[self.path]
                command = {**data, "action": action}
                if action != "decision":
                    command.setdefault("id", "http-" + uuid.uuid4().hex)
                if action == "media":
                    command["name"] = data.get("name", data.get("action"))
                result = runtime.command(command)
            elif self.path == "/clipboard/copy":
                text = data.get("text")
                if not isinstance(text, str):
                    raise ValueError("text must be a string")
                runtime.launcher.run(["wl-copy"], input_data=text)
                result = {"ok": True}
            else:
                with runtime.notes.lock:
                    notes = runtime.notes.load()
                    if self.path == "/notes/add":
                        text = data.get("text")
                        if not isinstance(text, str) or not text.strip():
                            raise ValueError("A nonempty text string is required")
                        notes.insert(0, {"id": uuid.uuid4().hex, "text": text.strip(), "time": time.strftime("%H:%M")})
                    else:
                        identity = data.get("id")
                        if isinstance(identity, bool) or not isinstance(identity, (str, int)):
                            raise ValueError("A note id is required")
                        notes = [note for note in notes if note["id"] != identity]
                    runtime.notes.save(notes)
                    runtime.emit({"event": "NotesUpdated", "notes": notes})
                result = {"ok": True, "status": "ok"}
            self.send_json(200 if result.get("ok") else 400, result)
        except (ValueError, UnicodeError, RecursionError) as exc:
            # Do not echo input/JSON parser excerpts into diagnostics or responses.
            self.send_json(400, {"ok": False, "message": "Invalid request body or action"})
        except (socket.timeout, TimeoutError):
            self.send_json(408, {"ok": False, "message": "Request timed out"})
        except Exception as exc:
            diagnostic("HTTP action failed", exc)
            self.send_json(500, {"ok": False, "message": "Local action failed"})

    def do_OPTIONS(self):
        if self.authorized():
            self.send_json(405, {"ok": False, "message": "Method not allowed"})

    do_HEAD = do_OPTIONS
    do_PUT = do_OPTIONS
    do_DELETE = do_OPTIONS
    do_PATCH = do_OPTIONS
