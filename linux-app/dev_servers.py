"""Managed local dev servers for the Dynamic Island (php artisan serve / npm run dev).

Long-running services run in their own sessions (start_new_session) so they
survive bridge restarts; state persists next to the bridge token and is
re-attached on startup. Commands are fixed templates built from a trusted
project config — no shell, no user-controlled strings.
"""
import json
import os
import shutil
import signal
import socket
import subprocess
import sys
import threading
import time
from pathlib import Path

SERVICES = ("php", "npm")
LABELS = {"php": "artisan serve", "npm": "npm run dev"}


class DevServerManager:
    def __init__(self, projects, root, emit, directory, stop=None,
                 command_builder=None, availability=None):
        # projects: mochi_bridge PROJECT_CONFIGS tuples (id, name, staging, production, local)
        self.projects = [p for p in projects if isinstance(p, (list, tuple)) and len(p) >= 5]
        self.root = Path(root)
        self.emit = emit
        self.directory = Path(directory)
        self.stop_event = stop if stop is not None else threading.Event()
        self._command_builder = command_builder
        self._availability = availability
        self.lock = threading.RLock()
        self.state = {}      # "project:service" -> {pid, cwd, port, cmd}
        self.stopping = {}   # key -> entry waiting out its SIGTERM grace period
        self.children = set()  # pids spawned by THIS instance (reapable here)
        if self.projects:
            self._load()
        threading.Thread(target=self._monitor_loop, daemon=True).start()

    # ---------- introspection ----------

    def _path(self, project_id):
        return self.root / project_id

    def _port(self, project):
        local = project[4] or ""
        if "://" in local:
            try:
                return int(local.rsplit(":", 1)[1])
            except (ValueError, IndexError):
                pass
        return 8000

    def _available(self, path, service):
        if self._availability is not None:
            return bool(self._availability(path, service))
        if service == "php":
            return (path / "artisan").is_file() and shutil.which("php") is not None
        package = path / "package.json"
        if not package.is_file() or shutil.which("npm") is None:
            return False
        try:
            scripts = json.loads(package.read_text(encoding="utf-8")).get("scripts") or {}
        except (OSError, ValueError):
            return False
        return "dev" in scripts

    @staticmethod
    def _alive(entry):
        pid = entry.get("pid")
        if not isinstance(pid, int) or pid <= 0:
            return False
        try:
            os.kill(pid, 0)
        except OSError:
            return False
        try:
            return os.readlink("/proc/%d/cwd" % pid) == entry.get("cwd")
        except OSError:
            return False

    def _project(self, project_id):
        if not isinstance(project_id, str) or not project_id:
            raise ValueError("Project id wajib diisi")
        for project in self.projects:
            if project[0] == project_id:
                return project
        raise ValueError("Project tidak dikenal: " + project_id)

    def _wanted(self, services):
        if services is None:
            return list(SERVICES)
        if not isinstance(services, list) or not services:
            raise ValueError("services harus berupa list tidak kosong")
        for service in services:
            if service not in SERVICES:
                raise ValueError("Service tidak dikenal: " + str(service))
        return [s for s in SERVICES if s in services]

    def status(self):
        output = []
        changed = False
        with self.lock:
            for project in self.projects:
                project_id, name = project[0], project[1]
                path = self._path(project_id)
                services = []
                for service in SERVICES:
                    key = project_id + ":" + service
                    entry = self.state.get(key)
                    running = bool(entry and self._alive(entry))
                    if entry and not running:
                        self.state.pop(key, None)
                        changed = True
                    available = self._available(path, service)
                    services.append({
                        "key": service,
                        "label": LABELS[service],
                        "available": available,
                        "running": running,
                        "pid": entry["pid"] if running else None,
                        "port": self._port(project) if service == "php" and available else None,
                    })
                output.append({"id": project_id, "name": name, "services": services})
            if changed:
                self._save_locked()
        return output

    def emit_status(self):
        self.emit({"event": "DevServerStatus", "projects": self.status()})

    # ---------- persistence ----------

    def _save_locked(self):
        try:
            self.directory.mkdir(mode=0o700, exist_ok=True)
            temp = self.directory / ("devservers-%d.tmp" % os.getpid())
            temp.write_text(json.dumps(self.state), encoding="utf-8")
            os.chmod(temp, 0o600)
            os.replace(temp, self.directory / "devservers.json")
        except OSError as exc:
            print("dev-servers: gagal simpan state: %s" % exc, file=sys.stderr, flush=True)

    def _load(self):
        try:
            raw = json.loads((self.directory / "devservers.json").read_text(encoding="utf-8"))
        except (OSError, ValueError):
            return
        if not isinstance(raw, dict):
            return
        # Muat semua entri berbentuk benar; entri mati dibersihkan oleh
        # status()/monitor berikutnya dan disimpan ulang.
        for key, entry in raw.items():
            if isinstance(entry, dict) and isinstance(entry.get("pid"), int):
                self.state[key] = entry

    # ---------- start / stop ----------

    def _command(self, project, service, port):
        if self._command_builder is not None:
            return list(self._command_builder(project[0], service, port))
        if service == "php":
            return ["php", "artisan", "serve", "--host=127.0.0.1", "--port=" + str(port)]
        return ["npm", "run", "dev"]

    def _port_owner(self, port):
        with self.lock:
            for key, entry in self.state.items():
                if key.endswith(":php") and entry.get("port") == port and self._alive(entry):
                    return key.split(":", 1)[0]
        return None

    @staticmethod
    def _port_busy(port):
        with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as sock:
            sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
            try:
                sock.bind(("127.0.0.1", port))
            except OSError:
                return True
        return False

    def start(self, project_id, services=None):
        project = self._project(project_id)
        wanted = self._wanted(services)
        name, path = project[1], self._path(project[0])
        if not path.is_dir():
            raise ValueError("Folder project tidak ditemukan: " + project[0])
        plan, already, skipped = [], [], []
        for service in wanted:
            if not self._available(path, service):
                # Start-all (services=None) melewati service yang tidak tersedia;
                # request eksplisit per service (toggle chip) tetap ditolak.
                if services:
                    raise ValueError("%s tidak tersedia untuk %s" % (service, name))
                skipped.append(service)
                continue
            key = project[0] + ":" + service
            with self.lock:
                entry = self.state.get(key)
            if entry and self._alive(entry):
                already.append(service)
                continue
            port = self._port(project) if service == "php" else None
            if service == "php":
                owner = self._port_owner(port)
                if owner and owner != project[0]:
                    # Otomatis hentikan project lain yang sedang memakai port ini agar bisa ganti-gantian
                    try:
                        self.stop(owner, ["php"])
                        time.sleep(0.4)
                    except Exception:
                        pass
                if self._port_busy(port):
                    raise ValueError("Port %d sedang dipakai di luar QBot" % port)
            plan.append((service, key, port))
        started = []
        for service, key, port in plan:
            cmd = self._command(project, service, port)
            log_dir = self.directory / "devlog"
            try:
                log_dir.mkdir(parents=True, exist_ok=True)
                handle = open(log_dir / ("%s-%s.log" % (project[0], service)),
                              "w", encoding="utf-8", errors="replace")
            except OSError as exc:
                raise ValueError("Gagal membuka log %s: %s" % (service, exc))
            try:
                proc = subprocess.Popen(cmd, cwd=str(path), stdin=subprocess.DEVNULL,
                                        stdout=handle, stderr=subprocess.STDOUT,
                                        start_new_session=True)
            except OSError as exc:
                handle.close()
                raise ValueError("Gagal menjalankan %s: %s" % (service, exc))
            handle.close()
            with self.lock:
                self.state[key] = {"pid": proc.pid, "cwd": str(path),
                                   "port": port, "cmd": cmd}
                self.children.add(proc.pid)
                self._save_locked()
            started.append(service)
        if started:
            threading.Thread(target=self._verify, args=(project, started),
                             daemon=True).start()
            message = "Menjalankan %s untuk %s" % (", ".join(started), name)
            if skipped:
                message += " — dilewati: %s (tidak tersedia)" % ", ".join(skipped)
        elif already:
            message = "Sudah berjalan: %s (%s)" % (", ".join(already), name)
        else:
            raise ValueError("Tidak ada service yang bisa dijalankan untuk " + name)
        self.emit_status()
        return message

    def stop(self, project_id, services=None):
        project = self._project(project_id)
        wanted = self._wanted(services)
        name = project[1]
        stopped = []
        for service in wanted:
            key = project[0] + ":" + service
            with self.lock:
                entry = self.state.pop(key, None)
                if not entry:
                    continue
                if not self._alive(entry):
                    self._save_locked()
                    continue
                entry["deadline"] = time.monotonic() + 2.5
                entry["killed"] = False
                self.stopping[key] = entry
                self._save_locked()
            try:
                os.killpg(entry["pid"], signal.SIGTERM)
            except OSError:
                pass
            stopped.append(service)
        self.emit_status()
        if stopped:
            return "Menghentikan %s untuk %s" % (", ".join(stopped), name)
        return "Tidak ada service yang berjalan untuk %s" % name

    def _verify(self, project, services):
        time.sleep(1.6)
        failed = []
        for service in services:
            key = project[0] + ":" + service
            with self.lock:
                entry = self.state.get(key)
                if not entry or self._alive(entry):
                    continue
                self.state.pop(key, None)
                self._save_locked()
            tail = self._log_tail(project[0], service)
            failed.append("%s gagal: %s" % (service, tail or "berhenti tanpa pesan"))
        if failed:
            self.emit({"event": "ActionResult", "id": "", "ok": False,
                       "message": "; ".join(failed)})
        self.emit_status()

    def _log_tail(self, project_id, service, limit=160):
        path = self.directory / "devlog" / ("%s-%s.log" % (project_id, service))
        try:
            data = path.read_text(encoding="utf-8", errors="replace")
        except OSError:
            return ""
        return " ".join(data.strip().split())[-limit:]

    # ---------- monitor ----------

    def _monitor_loop(self):
        while not self.stop_event.wait(1.0):
            self._reap_children()
            self._advance_stopping()
            self._prune_dead()

    def _reap_children(self):
        finished = []
        with self.lock:
            pids = list(self.children)
        for pid in pids:
            try:
                reaped, _ = os.waitpid(pid, os.WNOHANG)
            except (ChildProcessError, OSError):
                with self.lock:
                    self.children.discard(pid)
                continue
            if reaped:
                with self.lock:
                    self.children.discard(pid)
                finished.append(pid)
        if not finished:
            return
        died = []
        with self.lock:
            for key, entry in list(self.state.items()):
                if entry.get("pid") in finished:
                    self.state.pop(key, None)
                    died.append(key)
            if died:
                self._save_locked()
        for key in died:
            project_id, service = key.split(":", 1)
            self.emit({"event": "ActionResult", "id": "", "ok": False,
                       "message": "%s (%s) berhenti sendiri" % (service, project_id)})
        if died:
            self.emit_status()

    def _advance_stopping(self):
        now = time.monotonic()
        with self.lock:
            items = list(self.stopping.items())
        for key, entry in items:
            if not self._alive(entry):
                with self.lock:
                    self.stopping.pop(key, None)
                continue
            if now >= entry.get("deadline", 0):
                if not entry.get("killed"):
                    try:
                        os.killpg(entry["pid"], signal.SIGKILL)
                    except OSError:
                        pass
                    with self.lock:
                        entry["killed"] = True
                        entry["deadline"] = now + 1.5
                else:
                    with self.lock:
                        self.stopping.pop(key, None)

    def _prune_dead(self):
        died = []
        with self.lock:
            for key, entry in list(self.state.items()):
                if key in self.stopping:
                    continue
                if not self._alive(entry):
                    self.state.pop(key, None)
                    died.append(key)
            if died:
                self._save_locked()
        if died:
            self.emit_status()
