import json
import os
import signal
import socket
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from dev_servers import DevServerManager

PROJECTS = [("demo", "Demo App", "", "", "http://127.0.0.1:18099")]


class ProbeManager(DevServerManager):
    """Deterministic commands and capabilities for tests."""

    def _available(self, path, service):
        return True

    def _command(self, project, service, port):
        return ["sleep", "60"]


class DevServerManagerTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        (self.root / "demo").mkdir()
        self.events = []
        self.stop_event = threading.Event()
        self.manager = self._manager()

    def tearDown(self):
        try:
            self.manager.stop("demo")
        except Exception:
            pass
        self.stop_event.set()
        deadline = time.monotonic() + 4
        while time.monotonic() < deadline and any(
                self._pid_alive(p) for p in list(self.manager.children)):
            time.sleep(0.1)
        for pid in list(self.manager.children):
            if self._pid_alive(pid):
                try:
                    os.kill(pid, signal.SIGKILL)
                except OSError:
                    pass
        self.tmp.cleanup()

    def _manager(self):
        return ProbeManager(PROJECTS, self.root, self.events.append,
                            self.root / "runtime", stop=self.stop_event)

    @staticmethod
    def _pid_alive(pid):
        try:
            os.kill(pid, 0)
        except OSError:
            return False
        try:
            os.readlink("/proc/%d/cwd" % pid)
            return True
        except OSError:
            return False

    def _wait_until(self, predicate, timeout=4.0):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            if predicate():
                return True
            time.sleep(0.05)
        return False

    def test_status_shape_and_defaults(self):
        status = self.manager.status()
        self.assertEqual(len(status), 1)
        self.assertEqual(status[0]["id"], "demo")
        self.assertEqual([s["key"] for s in status[0]["services"]], ["php", "npm"])
        for service in status[0]["services"]:
            self.assertTrue(service["available"])
            self.assertFalse(service["running"])
            self.assertIsNone(service["pid"])
        self.assertEqual(status[0]["services"][0]["port"], 18099)
        self.assertIsNone(status[0]["services"][1]["port"])

    def test_rejects_unknown_project_and_service(self):
        with self.assertRaises(ValueError):
            self.manager.start("unknown")
        with self.assertRaises(ValueError):
            self.manager.start("demo", ["redis"])
        with self.assertRaises(ValueError):
            self.manager.stop("")
        with self.assertRaises(ValueError):
            self.manager.start("demo", "php")

    def test_start_all_skips_unavailable_services(self):
        class PhplessManager(ProbeManager):
            def _available(self, path, service):
                return service == "npm"

        mgr = PhplessManager(PROJECTS, self.root, self.events.append,
                             self.root / "runtime2", stop=self.stop_event)
        try:
            message = mgr.start("demo")
            self.assertIn("Menjalankan npm", message)
            self.assertIn("dilewati", message)
            services = {s["key"]: s for s in mgr.status()[0]["services"]}
            self.assertTrue(services["npm"]["running"])
            self.assertFalse(services["php"]["running"])
            with self.assertRaises(ValueError):
                mgr.start("demo", ["php"])
        finally:
            try:
                mgr.stop("demo")
            except Exception:
                pass

    def test_start_reports_running_then_stop_kills(self):
        message = self.manager.start("demo")
        self.assertIn("Menjalankan", message)
        status = self.manager.status()[0]["services"]
        self.assertTrue(all(s["running"] for s in status))
        pid = status[0]["pid"]
        self.assertTrue(self._pid_alive(pid))

        again = self.manager.start("demo")
        self.assertIn("Sudah berjalan", again)

        stop_message = self.manager.stop("demo")
        self.assertIn("Menghentikan", stop_message)
        status = self.manager.status()[0]["services"]
        self.assertFalse(any(s["running"] for s in status))
        self.assertTrue(self._wait_until(lambda: not self._pid_alive(pid)),
                        "proses masih hidup setelah stop")

        events = [e["event"] for e in self.events]
        self.assertIn("DevServerStatus", events)

    def test_partial_service_stop(self):
        self.manager.start("demo")
        self.manager.stop("demo", ["php"])
        services = {s["key"]: s for s in self.manager.status()[0]["services"]}
        self.assertFalse(services["php"]["running"])
        self.assertTrue(services["npm"]["running"])

    def test_port_conflict_is_rejected(self):
        blocker = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        blocker.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        blocker.bind(("127.0.0.1", 18099))
        blocker.listen(1)
        try:
            with self.assertRaises(ValueError) as ctx:
                self.manager.start("demo")
            self.assertIn("18099", str(ctx.exception))
        finally:
            blocker.close()

    def test_state_persists_and_second_manager_reattaches(self):
        self.manager.start("demo")
        pid = self.manager.status()[0]["services"][0]["pid"]

        second = self._manager()
        self.assertEqual(second.status()[0]["services"][0]["pid"], pid)
        self.assertTrue(second.status()[0]["services"][0]["running"])

        second.stop("demo")
        self.assertTrue(self._wait_until(lambda: not self._pid_alive(pid)),
                        "proses masih hidup setelah stop oleh manager kedua")

    def test_dead_pid_is_pruned_from_state(self):
        proc = subprocess.Popen(["true"])
        proc.wait()
        state = {"demo:php": {"pid": proc.pid, "cwd": str(self.root / "demo"),
                              "port": 18099, "cmd": ["true"]}}
        (self.root / "runtime").mkdir()
        (self.root / "runtime" / "devservers.json").write_text(json.dumps(state))

        fresh = self._manager()
        services = {s["key"]: s for s in fresh.status()[0]["services"]}
        self.assertFalse(services["php"]["running"])
        raw = (self.root / "runtime" / "devservers.json").read_text()
        self.assertNotIn(str(proc.pid), raw)


if __name__ == "__main__":
    unittest.main()
