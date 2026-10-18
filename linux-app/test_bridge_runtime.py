"""Isolated stdlib tests: no real Hermes, desktop commands, notes or main port."""
import asyncio
from concurrent.futures import ThreadPoolExecutor
from contextlib import redirect_stderr, redirect_stdout
import http.client
import io
import json
import os
from pathlib import Path
import socket
import stat
import subprocess
import tempfile
import threading
import time
import unittest
from unittest.mock import Mock, patch

import bridge_client
import bridge_runtime as br
import mochi_bridge


class RuntimeCase(unittest.TestCase):
    def setUp(self):
        self.stream = io.StringIO()
        self.notes = Mock()
        self.launcher = Mock()
        self.launcher.launch.return_value = "launched"
        self.launcher.media.return_value = "completed"
        self.runtime = br.BridgeRuntime(br.EventEmitter(self.stream), self.notes, self.launcher, rpc_timeout=0.15)

    def events(self):
        return [json.loads(line) for line in self.stream.getvalue().splitlines()]

    def approval(self, sid="session", rid="request", **payload):
        self.runtime.handle_ws({"params": {"type": "approval.request", "session_id": sid,
                                         "payload": {"request_id": rid, "command": "example", **payload}}})

    def decision(self, **values):
        return self.runtime.command({"id": "command", "action": "decision", "session_id": "session",
                                     "request_id": "request", "decision": "allow", **values})


class EmitterTests(RuntimeCase):
    def test_parallel_no_loss_and_per_producer_order(self):
        def produce(index):
            for sequence in range(100):
                self.runtime.emit({"event": "PreToolUse", "producer": index, "sequence": sequence,
                                   "message": "line one\nline two"})
        with ThreadPoolExecutor(max_workers=8) as pool:
            list(pool.map(produce, range(8)))
        events = self.events()
        self.assertEqual(len(events), 800)
        for index in range(8):
            self.assertEqual([e["sequence"] for e in events if e["producer"] == index], list(range(100)))

    def test_stdin_command_order_and_eof(self):
        commands = [{"id": str(i), "action": "media", "name": "next"} for i in range(30)]
        self.runtime.read_stdin(io.StringIO("\n".join(map(json.dumps, commands))), True)
        self.assertEqual([e["id"] for e in self.events()], list(map(str, range(30))))
        self.assertTrue(self.runtime.stop.is_set())

    def test_standalone_eof_does_not_stop(self):
        self.runtime.read_stdin(io.StringIO(""))
        self.assertFalse(self.runtime.stop.is_set())

    def test_invalid_stdin_is_structured_and_recovers(self):
        self.runtime.read_stdin(io.StringIO('invalid\n[]\n{"id":"a","action":"media","name":"next"}\n'))
        self.assertEqual([e["ok"] for e in self.events()], [False, False, True])

    def test_oversized_line_is_not_executed(self):
        self.runtime.read_stdin(io.StringIO("x" * (br.MAX_BODY + 2)), True)
        self.launcher.launch.assert_not_called()
        self.assertFalse(self.events()[0]["ok"])

    def test_synthetic_permission_cannot_be_decided(self):
        self.runtime.publish_event({"event": "PermissionRequest", "session_id": "session",
                                    "request_id": "request", "actionable": True})
        self.assertFalse(self.events()[0]["actionable"])
        self.assertEqual(self.runtime.pending, {})
        self.assertFalse(self.decision()["ok"])

    def test_ordinary_events_not_lost_while_approval_pending(self):
        self.runtime.ws = object()
        self.approval()
        for event in ("TaskStarted", "PreToolUse", "PostToolUse", "StopSuccess"):
            self.runtime.publish_event({"event": event, "message": event})
        self.assertEqual(len(self.events()), 5)
        self.assertIn(("session", "request"), self.runtime.pending)


class AckTests(RuntimeCase):
    def setUp(self):
        super().setUp()
        self.loop = asyncio.new_event_loop()
        self.thread = threading.Thread(target=self.loop.run_forever)
        self.thread.start()
        self.sent = []
        self.sent_event = threading.Event()
        self.response = None
        self.send_error = False

        class FakeWS:
            async def send(inner, raw):
                if self.send_error:
                    raise OSError("SECRET must not leak")
                message = json.loads(raw)
                self.sent.append(message)
                self.sent_event.set()
                if self.response is not None:
                    self.runtime.handle_ws({"jsonrpc": "2.0", "id": message["id"], **self.response})

        self.runtime.connected(FakeWS(), self.loop)
        self.approval()

    def tearDown(self):
        self.runtime.disconnected()
        self.loop.call_soon_threadsafe(self.loop.stop)
        self.thread.join(timeout=2)
        self.loop.close()

    def test_positive_ack_and_exact_wire_identity(self):
        self.response = {"result": {"ok": True}}
        result = self.decision()
        self.assertTrue(result["ok"])
        self.assertEqual(self.sent[0]["params"], {"session_id": "session", "request_id": "request", "choice": "approve"})
        self.assertEqual(self.sent[0]["method"], "approval.respond")
        self.assertNotIn(("session", "request"), self.runtime.pending)
        self.assertFalse(self.decision()["ok"])
        count = len(self.events())
        self.approval()
        self.assertEqual(len(self.events()), count)

    def test_deny_wire_choice(self):
        self.response = {"result": True}
        self.assertTrue(self.decision(decision="deny")["ok"])
        self.assertEqual(self.sent[0]["params"]["choice"], "deny")

    def test_rpc_error_is_not_success_and_allows_retry(self):
        self.response = {"error": {"code": -32000, "message": "SECRET"}}
        result = self.decision()
        self.assertFalse(result["ok"])
        self.assertNotIn("SECRET", result["message"])
        self.assertEqual(self.runtime.pending[("session", "request")], "ready")
        self.response = {"result": {"success": True}}
        self.assertTrue(self.decision(id="retry")["ok"])
        self.assertNotEqual(self.sent[0]["id"], self.sent[1]["id"])

    def test_timeout_and_late_ack_never_claim_success(self):
        result = self.decision()
        self.assertFalse(result["ok"])
        self.assertIn("Timed out", result["message"])
        self.runtime.handle_ws({"jsonrpc": "2.0", "id": self.sent[0]["id"], "result": True})
        self.assertFalse(self.decision(id="retry")["ok"])
        self.assertEqual(len(self.sent), 1)
        self.assertFalse(any(e.get("ok") for e in self.events()))

    def test_opaque_ack_is_not_confirmation(self):
        for result in (None, {}, False, {"ok": False}, {"accepted": False}, {"ok": True, "status": "rejected"}, "ok"):
            self.assertFalse(br.BridgeRuntime.acknowledged({"jsonrpc": "2.0", "result": result}))
        self.response = {"result": {}}
        self.assertFalse(self.decision()["ok"])

    def test_explicit_negative_result_cannot_succeed(self):
        self.response = {"result": {"ok": False}}
        self.assertFalse(self.decision()["ok"])
        self.assertFalse(self.decision(id="retry")["ok"])
        self.assertEqual(len(self.sent), 1)

    def test_external_notification_is_not_rpc_ack(self):
        with ThreadPoolExecutor(max_workers=1) as pool:
            result = pool.submit(self.decision)
            self.assertTrue(self.sent_event.wait(1))
            self.runtime.handle_ws({"params": {"type": "approval.respond", "session_id": "session",
                                               "payload": {"request_id": "request"}}})
            self.assertFalse(result.result(timeout=1)["ok"])
        self.assertEqual(self.runtime.pending, {})
        self.assertEqual(len([e for e in self.events() if e["event"] == "ApprovalResolved"]), 1)

    def test_duplicate_concurrent_submission(self):
        with ThreadPoolExecutor(max_workers=2) as pool:
            first = pool.submit(self.decision)
            self.assertTrue(self.sent_event.wait(1))
            self.assertFalse(self.decision(id="duplicate")["ok"])
            self.runtime.handle_ws({"jsonrpc": "2.0", "id": self.sent[0]["id"], "result": True})
            self.assertTrue(first.result(timeout=1)["ok"])
        self.assertEqual(len(self.sent), 1)

    def test_out_of_order_replies_correlate(self):
        self.runtime.rpc_timeout = 1
        self.approval("other", "request")
        with ThreadPoolExecutor(max_workers=2) as pool:
            first = pool.submit(self.decision)
            self.assertTrue(self.sent_event.wait(1))
            self.sent_event.clear()
            second = pool.submit(self.decision, id="second", session_id="other")
            self.assertTrue(self.sent_event.wait(1))
            self.runtime.handle_ws({"jsonrpc": "2.0", "id": "unrelated", "result": True})
            self.assertFalse(first.done())
            self.assertFalse(second.done())
            self.runtime.handle_ws({"jsonrpc": "2.0", "id": self.sent[1]["id"], "error": {"code": -1}})
            self.assertFalse(second.result(timeout=1)["ok"])
            self.assertFalse(first.done())
            self.runtime.handle_ws({"jsonrpc": "2.0", "id": self.sent[0]["id"], "result": {"status": "ok"}})
            self.assertTrue(first.result(timeout=1)["ok"])

    def test_disconnect_unblocks_waiter_without_success(self):
        self.runtime.rpc_timeout = 5
        with ThreadPoolExecutor(max_workers=1) as pool:
            first = pool.submit(self.decision)
            self.assertTrue(self.sent_event.wait(1))
            with redirect_stderr(io.StringIO()):
                self.runtime.disconnected()
                self.assertFalse(first.result(timeout=1)["ok"])
        self.assertEqual(self.runtime.pending, {})
        self.assertEqual(self.runtime.calls, {})

    def test_send_error_is_failure_and_redacted(self):
        self.send_error = True
        stderr = io.StringIO()
        with redirect_stderr(stderr):
            self.assertFalse(self.decision()["ok"])
        self.assertNotIn("SECRET", stderr.getvalue())

    def test_external_resolution_exact_identity_only(self):
        self.approval("other", "request")
        for sid, rid in (("session", None), (None, "request"), ("session", "stale")):
            with redirect_stderr(io.StringIO()):
                self.runtime.handle_ws({"params": {"type": "approval.respond", "session_id": sid,
                                                   "payload": {"request_id": rid}}})
        self.assertEqual(len(self.runtime.pending), 2)
        self.runtime.handle_ws({"params": {"type": "approval.respond", "session_id": "other",
                                           "payload": {"request_id": "request"}}})
        self.assertEqual(list(self.runtime.pending), [("session", "request")])
        event = self.events()[-1]
        self.assertEqual(event, {"event": "ApprovalResolved", "session_id": "other", "request_id": "request"})

    def test_duplicate_approval_does_not_overwrite_or_reemit(self):
        count = len(self.events())
        self.approval(command="different content")
        self.assertEqual(len(self.events()), count)
        with redirect_stderr(io.StringIO()):
            for sid, rid in (("", "request"), ("session", None), ("session", 4)):
                self.approval(sid, rid)
        self.assertEqual(len(self.runtime.pending), 1)

    def test_invalid_decisions_never_send(self):
        for values in ({"id": ""}, {"decision": "approve"}, {"session_id": ""},
                       {"session_id": "other"}, {"request_id": "stale"}, {"request_id": None}):
            self.assertFalse(self.decision(**values)["ok"])
        self.assertEqual(self.sent, [])


class NotesTests(unittest.TestCase):
    def test_fifo_load_is_rejected_without_blocking(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "notes"
            os.mkfifo(path, 0o600)
            with self.assertRaises(ValueError):
                br.NotesStore(path).load()

    def test_atomic_save_and_validate(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / ".config/notes.json"
            notes = br.NotesStore(path)
            data = [{"id": 1, "text": "hello", "time": "12:34"}]
            notes.save(data)
            self.assertEqual(notes.load(), data)
            self.assertEqual(stat.S_IMODE(path.stat().st_mode), 0o600)
            for invalid in ({}, ["text"], [{"id": 1}], data + data, [{"id": True, "text": "bad"}]):
                with self.assertRaises(ValueError):
                    notes.save(invalid)
                self.assertEqual(notes.load(), data)
            with patch("bridge_runtime.os.replace", side_effect=OSError("simulated")):
                with self.assertRaises(OSError):
                    notes.save([])
            self.assertEqual(notes.load(), data)
            self.assertEqual(list(path.parent.iterdir()), [path])

    def test_replace_does_not_follow_destination_symlink(self):
        with tempfile.TemporaryDirectory() as directory:
            target = Path(directory) / "target"
            target.write_text("unchanged")
            path = Path(directory) / "notes"
            path.symlink_to(target)
            br.NotesStore(path).save([])
            self.assertEqual(target.read_text(), "unchanged")
            self.assertFalse(path.is_symlink())


class LauncherTests(unittest.TestCase):
    def setUp(self):
        self.launcher = br.Launcher()

    def test_arbitrary_commands_and_bad_inputs_rejected(self):
        commands = [{"cmd": "touch /tmp/unsafe"}, {"name": "editor", "cmd": ["sh", "-c", "bad"]},
                    {"name": "unknown"}, {"name": "open_url", "url": "file:///tmp"},
                    {"name": "open_url", "url": "https://example.org\n--bad"},
                    {"name": "open_url", "url": "https://user:pass@example.org"},
                    {"name": "open_url", "url": "--help"}, {"name": "open_project", "path": "--help"}]
        with patch("bridge_runtime.subprocess.Popen") as popen, patch("bridge_runtime.subprocess.run") as run:
            for command in commands:
                with self.assertRaises(ValueError):
                    self.launcher.launch(command)
            with self.assertRaises(ValueError):
                self.launcher.media("next; bad")
            popen.assert_not_called()
            run.assert_not_called()

    def test_url_and_project_metacharacters_are_single_arguments(self):
        with tempfile.TemporaryDirectory(prefix="project ; ") as directory, patch("bridge_runtime.subprocess.Popen") as popen:
            self.launcher.launch({"name": "open_project", "path": directory})
            self.assertEqual(popen.call_args.args[0], ["code", "--", os.path.realpath(directory)])
            url = "https://example.org/;touch?x=$(bad)&y=1"
            self.launcher.launch({"name": "open_url", "url": url})
            self.assertEqual(popen.call_args.args[0], ["xdg-open", url])
            self.assertFalse(popen.call_args.kwargs["shell"])
            self.assertEqual(popen.call_args.kwargs["stdout"], subprocess.DEVNULL)
            self.assertEqual(popen.call_args.kwargs["stderr"], subprocess.DEVNULL)
            self.assertEqual(popen.call_args.kwargs["stdin"], subprocess.DEVNULL)

    def test_media_and_volume_no_stdout(self):
        with patch("bridge_runtime.subprocess.run", return_value=Mock(returncode=0)) as run:
            self.launcher.media("play-pause")
            self.assertEqual(run.call_args.args[0], ["playerctl", "play-pause"])
            self.launcher.launch({"name": "volume_down"})
            self.assertEqual(run.call_args.args[0], ["pactl", "set-sink-volume", "@DEFAULT_SINK@", "-5%"])
            self.assertFalse(run.call_args.kwargs["shell"])
            self.assertEqual(run.call_args.kwargs["stdout"], subprocess.DEVNULL)
            self.assertIn("timeout", run.call_args.kwargs)

    def test_screenshot_cancel_does_not_run_grim(self):
        with patch("bridge_runtime.shutil.which", return_value="mock"), patch("bridge_runtime.subprocess.run", return_value=Mock(returncode=1)) as run:
            with self.assertRaises(ValueError):
                self.launcher.launch({"name": "screenshot"})
            self.assertEqual(run.call_count, 1)
            self.assertEqual(run.call_args.args[0], ["slurp"])

    def test_screenshot_no_pipeline(self):
        with tempfile.TemporaryDirectory() as directory, patch("bridge_runtime.Path.home", return_value=Path(directory)), patch("bridge_runtime.shutil.which", return_value="mock"), patch("bridge_runtime.subprocess.run", side_effect=[Mock(returncode=0, stdout="1,2 30,40\n"), Mock(returncode=0)]) as run:
            self.launcher.launch({"name": "screenshot"})
            argv = run.call_args.args[0]
            self.assertEqual(argv[:3], ["grim", "-g", "1,2 30,40"])
            self.assertTrue(Path(argv[3]).is_file())
            self.assertFalse(run.call_args.kwargs["shell"])


class AgentEventTests(RuntimeCase):
    def test_agent_events_forwarded_with_project_and_truncated(self):
        self.runtime.publish_event({"event": "AgentToolStart", "agent": "opencode", "message": "x" * 500,
                                    "tool_name": "bash", "session_id": "s1", "project": "coucou"})
        event = self.events()[-1]
        self.assertEqual((event["event"], event["agent"], event["project"]), ("AgentToolStart", "opencode", "coucou"))
        self.assertEqual(len(event["message"]), 300)
        self.assertNotIn("actionable", event)

    def test_agent_events_validated(self):
        self.runtime.publish_event({"event": "AgentWaiting", "agent": "claude", "kind": "permission",
                                    "request_id": "r", "session_id": "s"})
        event = self.events()[-1]
        self.assertEqual(event["kind"], "permission")
        self.assertNotIn("request_id", event)
        for bad in ({"event": "AgentStop", "agent": "claude", "project": 5},
                    {"event": "AgentStop", "agent": "cursor"}, {"event": "AgentStop"}):
            with self.assertRaises(ValueError):
                self.runtime.publish_event(bad)


class AgentRequestTests(RuntimeCase):
    QUESTION = {"agent": "claude", "kind": "question", "request_id": "q1", "timeout": 5,
                "questions": [{"question": "Framework?", "header": "FW",
                               "options": [{"label": "React", "description": "x"}, {"label": "Vue"}]}]}

    def open_async(self, data, **kw):
        out = {}
        worker = threading.Thread(target=lambda: out.update(self.runtime.open_request(data, **kw)))
        worker.start()
        for _ in range(100):
            if self.runtime.agent_requests:
                break
            time.sleep(0.01)
        return worker, out

    def test_question_answered_from_island(self):
        worker, out = self.open_async(self.QUESTION)
        shown = [e for e in self.events() if e["event"] == "AgentRequest"][-1]
        self.assertEqual((shown["request_id"], shown["questions"][0]["options"][1]["label"]), ("claude:q1", "Vue"))
        result = self.runtime.command({"action": "agent_answer", "id": "a", "request_id": "claude:q1",
                                       "answer": {"answers": [["Vue"]]}})
        worker.join(2)
        self.assertTrue(result["ok"])
        self.assertEqual((out["status"], out["answer"]), ("answered", {"answers": [["Vue"]]}))
        self.assertEqual(self.events()[-2]["event"], "AgentRequestClosed")

    def test_invalid_answers_keep_request_open(self):
        worker, out = self.open_async({**self.QUESTION, "kind": "permission", "questions": None})
        for answer in ({"decision": "yes"}, {"answers": [["x"]]}, "allow"):
            self.assertFalse(self.runtime.command({"action": "agent_answer", "id": "a",
                                                   "request_id": "claude:q1", "answer": answer})["ok"])
        self.assertIn("claude:q1", self.runtime.agent_requests)
        self.runtime.command({"action": "agent_answer", "id": "b", "request_id": "claude:q1", "answer": {"decision": "deny"}})
        worker.join(2)
        self.assertEqual(out["answer"], {"decision": "deny"})

    def test_single_select_needs_one_answer(self):
        worker, out = self.open_async(self.QUESTION)
        self.assertFalse(self.runtime.command({"action": "agent_answer", "id": "a", "request_id": "claude:q1",
                                               "answer": {"answers": [["React", "Vue"]]}})["ok"])
        self.runtime.close_request("claude:q1", "cancelled")
        worker.join(2)
        self.assertEqual(out["status"], "cancelled")

    def test_timeout_and_disconnect_close_card(self):
        self.assertEqual(self.runtime.open_request({**self.QUESTION, "timeout": 1})["status"], "timeout")
        self.assertEqual(self.runtime.open_request(self.QUESTION, still_connected=lambda: False)["status"], "cancelled")
        closed = [e["reason"] for e in self.events() if e["event"] == "AgentRequestClosed"]
        self.assertEqual(closed, ["timeout", "cancelled"])
        self.assertEqual(self.runtime.agent_requests, {})

    def test_bad_requests_rejected(self):
        for bad in ({**self.QUESTION, "agent": "x"}, {**self.QUESTION, "kind": "x"},
                    {**self.QUESTION, "questions": []}, {**self.QUESTION, "timeout": 9999},
                    {**self.QUESTION, "request_id": ""}):
            with self.assertRaises(ValueError):
                self.runtime.open_request(bad)

    def test_hermes_clarify_answer_sent_over_rpc(self):
        self.runtime.handle_ws({"params": {"type": "clarify.request", "session_id": "s",
                                           "payload": {"request_id": "r1", "question": "Lanjut?",
                                                       "choices": ["Ya", "Tidak"]}}})
        self.assertIn("hermes:r1", self.runtime.agent_requests)
        sent = []
        with patch.object(self.runtime, "_hermes_rpc", side_effect=lambda m, p: sent.append((m, p))):
            ok = self.runtime.command({"action": "agent_answer", "id": "a", "request_id": "hermes:r1",
                                       "answer": {"answers": [["Ya"]]}})["ok"]
        self.assertTrue(ok)
        self.assertEqual(sent, [("clarify.respond", {"session_id": "s", "request_id": "r1", "answer": "Ya"})])
        self.runtime.handle_ws({"params": {"type": "clarify.request", "session_id": "s",
                                           "payload": {"request_id": "r2", "question": "Q", "choices": []}}})
        self.runtime.handle_ws({"params": {"type": "clarify.expire", "session_id": "s", "payload": {"request_id": "r2"}}})
        self.assertNotIn("hermes:r2", self.runtime.agent_requests)


class RunNoteTests(RuntimeCase):
    def test_runs_only_saved_command_notes(self):
        self.notes.load.return_value = [{"id": 17, "text": "git status", "tag": "cmd"},
                                        {"id": "m", "text": "beli kopi", "tag": "note"}]
        self.launcher.run_in_terminal.return_value = "opened"
        self.assertTrue(self.runtime.command({"action": "run_note", "id": "a", "note_id": "17"})["ok"])
        self.launcher.run_in_terminal.assert_called_once_with("git status")
        for note_id in ("m", "missing", None, True):
            self.assertFalse(self.runtime.command({"action": "run_note", "id": "b", "note_id": note_id})["ok"])
        self.assertEqual(self.launcher.run_in_terminal.call_count, 1)

    def test_terminal_receives_script_as_single_argument(self):
        script = 'echo "a; b" && ls $HOME'
        with patch("bridge_runtime.shutil.which", side_effect=lambda n: n == "kitty"), \
                patch("bridge_runtime.subprocess.Popen") as popen:
            br.Launcher().run_in_terminal(script)
        self.assertEqual(popen.call_args.args[0], ["kitty", "--hold", "sh", "-c", script])
        self.assertFalse(popen.call_args.kwargs["shell"])


class HTTPTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.environment = patch.dict(os.environ, {"XDG_RUNTIME_DIR": self.temp.name})
        self.environment.start()
        self.addCleanup(self.environment.stop)
        self.stream = io.StringIO()
        self.launcher = Mock()
        self.launcher.launch.return_value = "launched"
        self.runtime = br.BridgeRuntime(br.EventEmitter(self.stream), br.NotesStore(Path(self.temp.name) / "notes.json"), self.launcher)
        self.reader = Mock(return_value={"active": False})
        self.server = br.BridgeHTTPServer(("127.0.0.1", 0), self.runtime, self.reader)
        self.thread = threading.Thread(target=self.server.serve_forever, kwargs={"poll_interval": 0.01})
        self.thread.start()
        self.addCleanup(self.close_server)

    def close_server(self):
        self.server.shutdown()
        self.server.server_close()
        self.thread.join(timeout=2)

    def request(self, method, path, body=None, auth=True, headers=None):
        connection = http.client.HTTPConnection(*self.server.server_address, timeout=2)
        request_headers = {"Content-Type": "application/json"}
        if auth:
            request_headers["Authorization"] = "Bearer " + self.server.credentials.token
        request_headers.update(headers or {})
        if isinstance(body, (dict, list)):
            body = json.dumps(body)
        try:
            connection.request(method, path, body, request_headers)
            response = connection.getresponse()
            return response.status, json.loads(response.read())
        finally:
            connection.close()

    def test_auth_required_for_get_and_post(self):
        for method, path, body in (("GET", "/media", None), ("POST", "/event", {"event": "TaskStarted"})):
            self.assertEqual(self.request(method, path, body, auth=False)[0], 401)
            self.assertEqual(self.request(method, path, body, headers={"Authorization": "Bearer wrong"})[0], 401)
        self.assertEqual(self.request("GET", "/media"), (200, {"active": False}))

    def test_origin_rejected_even_with_token_and_unknown_method(self):
        for method in ("GET", "POST", "OPTIONS", "UNRECOGNIZED"):
            self.assertEqual(self.request(method, "/media", headers={"Origin": "null"})[0], 403)

    def test_unknown_paths_and_bad_json_are_errors(self):
        for method in ("GET", "POST"):
            self.assertEqual(self.request(method, "/unknown", {})[0], 404)
        for body in ("{", "[]", '{"event":"TaskStarted","x":NaN}'):
            self.assertEqual(self.request("POST", "/event", body)[0], 400)
        with patch.object(self.runtime, "launcher", br.Launcher()):
            self.assertEqual(self.request("POST", "/launch", {"cmd": "bad"})[0], 400)
        self.assertEqual(self.request("POST", "/event", {"event": "DecisionResult"})[0], 400)

    def test_body_limits_and_content_type(self):
        self.assertEqual(self.request("POST", "/event", "{}", headers={"Content-Length": str(br.MAX_BODY + 1)})[0], 400)
        self.assertEqual(self.request("POST", "/event", "{}", headers={"Content-Length": "-1"})[0], 400)
        self.assertEqual(self.request("POST", "/event", "{}", headers={"Content-Type": "text/plain"})[0], 400)
        self.assertEqual(self.request("POST", "/event", "{}", headers={"Transfer-Encoding": "chunked"})[0], 400)

    def test_socket_timeout(self):
        with patch("bridge_runtime.IO_TIMEOUT", 0.05):
            sock = socket.create_connection(self.server.server_address, timeout=1)
            try:
                token = self.server.credentials.token
                sock.sendall(("POST /event HTTP/1.0\r\nAuthorization: Bearer " + token +
                              "\r\nContent-Type: application/json\r\nContent-Length: 50\r\n\r\n{").encode())
                response = sock.recv(4096)
                self.assertIn(b"408", response)
            finally:
                sock.close()

    def test_event_and_notes_routes(self):
        status, result = self.request("POST", "/event", {"event": "PermissionRequest", "session_id": "s", "request_id": "r"})
        self.assertEqual(status, 200)
        event = json.loads(self.stream.getvalue().splitlines()[0])
        self.assertFalse(event["actionable"])
        self.assertEqual(self.runtime.pending, {})
        self.assertEqual(self.request("POST", "/notes/add", {"text": "test"})[0], 200)
        status, notes = self.request("GET", "/notes")
        self.assertEqual(notes[0]["text"], "test")
        self.assertEqual(self.request("POST", "/notes/delete", {"id": notes[0]["id"]})[0], 200)
        self.assertEqual(self.request("GET", "/notes")[1], [])
        self.assertEqual(self.request("POST", "/notes/save", {"notes": "invalid"})[0], 400)
        self.assertEqual(self.request("POST", "/notes/save", {"notes": [{"id": "one", "text": "saved"}]})[0], 200)
        self.assertEqual(self.request("GET", "/notes")[1], [{"id": "one", "text": "saved"}])

    def test_http_decision_requires_explicit_command_and_request_ids(self):
        self.assertEqual(self.request("POST", "/decision", {"decision": "allow"})[0], 400)
        self.assertEqual(self.runtime.pending, {})

    def test_all_read_paths_preserved(self):
        for path in ("/media", "/sysinfo", "/usage", "/gitstatus", "/projects"):
            self.assertEqual(self.request("GET", path)[0], 200)
            self.reader.assert_called_with(path)

    def test_same_port_second_instance_cannot_clobber_token(self):
        token = bridge_client.read_token()
        with self.assertRaises(OSError):
            br.BridgeHTTPServer(self.server.server_address, self.runtime, self.reader)
        self.assertEqual(bridge_client.read_token(), token)

    def test_other_port_second_instance_cannot_clobber_token(self):
        token = bridge_client.read_token()
        with self.assertRaises(OSError):
            br.BridgeHTTPServer(("127.0.0.1", 0), self.runtime, self.reader)
        self.assertEqual(bridge_client.read_token(), token)

    def test_token_permissions_and_remove_only_own_file(self):
        path = self.server.credentials.path
        self.assertEqual(stat.S_IMODE(path.stat().st_mode), 0o600)
        self.assertEqual(stat.S_IMODE(path.parent.stat().st_mode), 0o700)
        replacement = path.parent / "replacement"
        replacement.write_text("replacement")
        os.replace(replacement, path)
        self.server.credentials.close()
        self.assertEqual(path.read_text(), "replacement")

    def test_client_and_cli_use_authenticated_local_server(self):
        with patch.dict(os.environ, {"HERMES_COUCOU_PORT": str(self.server.server_port)}):
            self.assertEqual(bridge_client.request("GET", "/media"), {"active": False})
            self.assertTrue(bridge_client.request("POST", "/event", {"event": "TaskStarted"})["ok"])
            stdout, stderr = io.StringIO(), io.StringIO()
            with redirect_stdout(stdout), redirect_stderr(stderr):
                self.assertEqual(bridge_client.main(["get", "/unknown"]), 1)
            self.assertEqual(len(stdout.getvalue().splitlines()), 1)
            self.assertFalse(json.loads(stdout.getvalue())["ok"])
            self.assertTrue(stderr.getvalue())


class LifecycleTests(unittest.TestCase):
    def test_token_cleanup(self):
        with tempfile.TemporaryDirectory() as directory, patch.dict(os.environ, {"XDG_RUNTIME_DIR": directory}):
            token = br.TokenFile()
            token.create()
            self.assertTrue(token.path.exists())
            token.close()
            self.assertFalse(token.path.exists())

    def test_fallback_directory_is_private_uid_specific(self):
        with tempfile.TemporaryDirectory() as directory, patch.dict(os.environ, {"XDG_RUNTIME_DIR": ""}), patch("bridge_client.tempfile.gettempdir", return_value=directory):
            token = br.TokenFile()
            token.create()
            try:
                self.assertEqual(token.path.parent.name, "hermes-coucou-" + str(os.getuid()))
                self.assertEqual(bridge_client.read_token(), token.token)
            finally:
                token.close()

    def test_runtime_symlink_rejected(self):
        with tempfile.TemporaryDirectory() as directory, patch.dict(os.environ, {"XDG_RUNTIME_DIR": directory}):
            target = Path(directory) / "actual"
            target.mkdir(mode=0o700)
            (Path(directory) / "hermes-coucou").symlink_to(target)
            with self.assertRaises(ValueError):
                br.TokenFile().create()

    def test_missing_websockets_reports_disconnected(self):
        runtime = br.BridgeRuntime(br.EventEmitter(io.StringIO()))
        with patch.dict("sys.modules", {"websockets.asyncio.client": None}), redirect_stderr(io.StringIO()):
            asyncio.run(br.hermes_ws_listener(runtime))
        self.assertFalse(runtime.status[0])
        self.assertIn("Missing dependency", runtime.status[1])

    def test_diagnostics_do_not_echo_exception_secrets(self):
        stderr = io.StringIO()
        with redirect_stderr(stderr):
            br.diagnostic("Connection failed", OSError("ws://localhost/?token=SECRET"))
        self.assertNotIn("SECRET", stderr.getvalue())

    def test_main_stdio_eof_cleans_up(self):
        with tempfile.TemporaryDirectory() as directory, patch.dict(os.environ, {"XDG_RUNTIME_DIR": directory}), patch("mochi_bridge.BridgeHTTPServer") as factory, patch("mochi_bridge.start_ws_listener_thread"), patch("mochi_bridge.signal.signal"), patch("mochi_bridge.importlib.util.find_spec", return_value=object()), patch("sys.stdin", io.StringIO("")), redirect_stdout(io.StringIO()) as stdout:
            self.assertEqual(mochi_bridge.main(["--stdio"]), 0)
            factory.return_value.server_close.assert_called_once()
            events = [json.loads(line) for line in stdout.getvalue().splitlines()]
            self.assertEqual(events[0], {"event": "BridgeReady"})


class ReadEndpointTests(unittest.TestCase):
    def test_media_schema_and_no_remote_fetch(self):
        with patch("mochi_bridge.output", side_effect=["spotify", "Song\nArtist\nAlbum\nhttps://example.org/art", "Playing"]):
            result = mochi_bridge.media()
        self.assertTrue(result["active"])
        self.assertEqual(result["artUrl"], "https://example.org/art")

    def test_usage_missing_database_does_not_create_it(self):
        with tempfile.TemporaryDirectory() as directory, patch("mochi_bridge.Path.home", return_value=Path(directory)):
            self.assertEqual(mochi_bridge.usage()["today"]["requests"], 0)
            self.assertEqual(list(Path(directory).iterdir()), [])

    def test_read_cache(self):
        endpoints = mochi_bridge.ReadEndpoints()
        endpoints.functions["/sysinfo"] = Mock(return_value={"cpu": 1})
        self.assertEqual(endpoints("/sysinfo"), endpoints("/sysinfo"))
        endpoints.functions["/sysinfo"].assert_called_once()


if __name__ == "__main__":
    unittest.main()
