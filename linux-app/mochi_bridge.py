#!/usr/bin/env python3
"""Persistent local bridge. Use --stdio when managed by the QML Process.

HTTP read schemas are kept compatible; event delivery is exclusively stdout
NDJSON (no mailbox). See bridge_runtime for commands, token security and ACKs.
"""
import argparse
from contextlib import closing, suppress
import importlib.util
import json
import os
from pathlib import Path
import platform
import signal
import sqlite3
import subprocess
import sys
import threading
import time

from bridge_runtime import (
    BridgeHTTPServer, BridgeRuntime, diagnostic, start_ws_listener_thread,
)

PORT = 4848
PROJECT_ROOT = Path.home() / "Projects/project-web"
PROJECT_CONFIGS = [
    ("best-cso", "Best CSO", "https://cso.brilian.dev/", "https://cso.best-operational.id/", "http://127.0.0.1:8000"),
    ("best-arsip", "Best Arsip", "https://archive.brilian.dev/", "https://archive.best-operational.id/", "http://127.0.0.1:8000"),
    ("sekretariat", "Best Office (Sekretariat)", "https://best-office.brilian.dev/", "https://office.best-operational.id/", "http://127.0.0.1:8000"),
    ("best-finance", "Best Finance", "", "https://finance.best-operational.id/", "http://127.0.0.1:8000"),
    ("best-warehouse", "Best Warehouse", "", "https://warehouse.best-operational.id/", "http://127.0.0.1:8000"),
    ("keuangan", "Keuangan Pribadi", "", "", "http://127.0.0.1:3000"),
]


def _ensure_runtime_python():
    """Re-exec with an interpreter that has websockets (approval dependency).

    Quickshell can be started without run.sh, so HERMES_COUCOU_PYTHON may be
    missing and the system python may lack websockets, silently disabling
    approvals. The env guard allows a single attempt so a broken environment
    still fails with the usual diagnostics instead of looping.
    """
    if os.environ.get("HERMES_COUCOU_REEXEC") == "1":
        return
    if importlib.util.find_spec("websockets") is not None:
        return
    candidates = [os.environ.get("HERMES_COUCOU_PYTHON", ""),
                  str(Path.home() / ".hermes/hermes-agent/venv/bin/python3")]
    for candidate in candidates:
        if not candidate:
            continue
        try:
            if os.path.realpath(candidate) == os.path.realpath(sys.executable):
                continue
            if not (os.path.isfile(candidate) and os.access(candidate, os.X_OK)):
                continue
            probe = subprocess.run([candidate, "-c", "import websockets"],
                                   capture_output=True, timeout=5)
            if probe.returncode != 0:
                continue
        except (OSError, subprocess.SubprocessError, ValueError):
            continue
        argv = [candidate, "-u", os.path.abspath(sys.argv[0])] + sys.argv[1:]
        os.execve(candidate, argv, {**os.environ, "HERMES_COUCOU_REEXEC": "1"})


def output(argv):
    result = subprocess.run(argv, shell=False, stdin=subprocess.DEVNULL,
                            capture_output=True, text=True, timeout=1)
    return result.stdout.strip() if result.returncode == 0 else ""


def media():
    result = {"active": False, "is_playing": False, "player": "Spotify",
              "title": "Tidak Ada Media", "artist": "Buka Spotify / Musik", "album": "", "artUrl": ""}
    try:
        players = output(["playerctl", "-l"]).splitlines()
        if not players:
            return result
        target = min(players, key=lambda p: (0 if "spotify" in p.lower() else
                                            1 if "plasma-browser-integration" in p.lower() else 2))
        # One metadata invocation keeps the total endpoint latency bounded. No
        # remote artwork downloads; use the MPRIS art URL directly.
        fields = output(["playerctl", "-p", target, "metadata", "--format",
                         "{{title}}\n{{artist}}\n{{album}}\n{{mpris:artUrl}}"])
        metadata = (fields.split("\n") + [""] * 4)[:4]
        result.update(active=True, is_playing=output(["playerctl", "-p", target, "status"]) == "Playing",
                      player="Spotify" if "spotify" in target.lower() else target,
                      title=metadata[0], artist=metadata[1], album=metadata[2], artUrl=metadata[3])
    except (OSError, subprocess.SubprocessError) as exc:
        diagnostic("Media unavailable", exc)
    return result


def sysinfo():
    result = {"cpu": 0, "ram_percent": 0, "ram_used": "0 GB", "ram_total": "0 GB",
              "uptime": "up", "kernel": platform.release(), "active_processes": 0}
    try:
        import psutil
        mem = psutil.virtual_memory()
        result.update(cpu=int(psutil.cpu_percent(interval=None)), ram_percent=int(mem.percent),
                      ram_used=f"{mem.used / 1024**3:.1f} GB", ram_total=f"{mem.total / 1024**3:.1f} GB",
                      active_processes=len(psutil.pids()))
    except (ImportError, OSError) as exc:
        diagnostic("Optional psutil data unavailable", exc)
    try:
        result["uptime"] = output(["uptime", "-p"]).removeprefix("up ") or "up"
    except (OSError, subprocess.SubprocessError):
        pass
    return result


def usage():
    result = {"available": False, "today": {"requests": 0, "cost": 0.0, "tokens": 0},
              "all60d": {"requests": 0, "cost": 0.0, "tokens": 0}, "activeModels": [], "recentLogs": []}
    path = Path.home() / ".9router/db/data.sqlite"
    if not path.is_file():
        return result
    try:
        with closing(sqlite3.connect(path.as_uri() + "?mode=ro", uri=True, timeout=1)) as conn:
            deadline = time.monotonic() + 2
            conn.set_progress_handler(lambda: int(time.monotonic() > deadline), 1000)
            # Baris terbaru belum tentu hari ini (hari tanpa request tidak punya
            # baris); dateKey bisa lokal atau UTC, jadi terima keduanya.
            today_keys = {time.strftime("%Y-%m-%d"), time.strftime("%Y-%m-%d", time.gmtime())}
            rows = conn.execute("SELECT dateKey, data FROM usageDaily ORDER BY dateKey DESC LIMIT 60").fetchall()
            for index, (date_key, data) in enumerate(rows):
                day = json.loads(data)
                counts = {"requests": int(day.get("requests") or 0), "cost": float(day.get("cost") or 0),
                          "tokens": int(day.get("promptTokens") or 0) + int(day.get("completionTokens") or 0)}
                for key, value in counts.items():
                    result["all60d"][key] += value
                if index == 0 and str(date_key) in today_keys:
                    result["today"] = counts
                    models = [{"name": info.get("rawModel") or key.split("|")[0],
                               "provider": info.get("provider", "antigravity"), "requests": info.get("requests", 0),
                               "cost": round(float(info.get("cost") or 0), 2)}
                              for key, info in day.get("byModel", {}).items()]
                    result["activeModels"] = sorted(models, key=lambda m: m["requests"], reverse=True)[:4]
            for key in ("today", "all60d"):
                result[key]["cost"] = round(result[key]["cost"], 2)
            rows = conn.execute("SELECT model, provider, cost, promptTokens + completionTokens, timestamp "
                                "FROM usageHistory ORDER BY id DESC LIMIT 3").fetchall()
            result["recentLogs"] = [{"model": row[0], "provider": row[1], "cost": round(float(row[2] or 0), 4),
                                     "tokens": row[3], "time": str(row[4]).split("T")[-1][:8]} for row in rows]
            result["available"] = True
    except (sqlite3.Error, ValueError, TypeError, AttributeError) as exc:
        diagnostic("Usage data unavailable", exc)
    return result


def git_mtime(path):
    try:
        return (path / ".git/logs/HEAD").stat().st_mtime
    except OSError:
        return 0


def git_info(path):
    result = {"repo": path.name, "branch": "master", "commits_today": 0, "modified": 0, "last_commit": "-"}
    try:
        prefix = ["git", "--no-optional-locks", "-C", str(path)]
        result["branch"] = output(prefix + ["rev-parse", "--abbrev-ref", "HEAD"]) or "master"
        count = output(prefix + ["rev-list", "--count", "--since=midnight", "HEAD"])
        result["commits_today"] = int(count) if count.isdigit() else 0
        result["modified"] = len(output(prefix + ["status", "--porcelain"]).splitlines())
        message = output(prefix + ["log", "-1", "--format=%s"])
        result["last_commit"] = message[:35] + ("..." if len(message) > 35 else "") if message else "-"
    except (OSError, subprocess.SubprocessError) as exc:
        diagnostic("Git data unavailable", exc)
    return result


def gitstatus():
    paths = [PROJECT_ROOT / name for name in ("best-cso", "best-arsip", "keuangan", "hermes-coucou")]
    return git_info(max(paths, key=git_mtime))


def projects():
    result = []
    for identity, name, staging, production, local in PROJECT_CONFIGS:
        path = PROJECT_ROOT / identity
        if not path.is_dir():
            continue
        info = git_info(path)
        info.pop("repo")
        result.append({**info, "id": identity, "name": name, "path": str(path), "staging": staging,
                       "production": production, "local": local, "mtime": git_mtime(path)})
    result.sort(key=lambda p: p["mtime"], reverse=True)
    active_id = result[0]["id"] if result else ""
    for project in result:
        project["is_active"] = project["id"] == active_id
    return {"active_id": active_id, "projects": result}


class ReadEndpoints:
    """Brief per-endpoint caching avoids overlapping expensive local probes."""
    def __init__(self):
        self.functions = {"/media": media, "/sysinfo": sysinfo, "/usage": usage,
                          "/gitstatus": gitstatus, "/projects": projects}
        self.locks = {path: threading.Lock() for path in self.functions}
        self.cache = {}

    def __call__(self, path):
        lock = self.locks[path]
        if not lock.acquire(timeout=25):
            raise TimeoutError("Read endpoint busy")
        try:
            cached = self.cache.get(path)
            ttl = 0.5 if path in ("/media", "/sysinfo") else 5
            if cached is None or time.monotonic() - cached[0] > ttl:
                value = self.functions[path]()
                self.cache[path] = (time.monotonic(), value)
            return self.cache[path][1]
        finally:
            lock.release()


def main(argv=None):
    _ensure_runtime_python()
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--stdio", action="store_true", help="Exit cleanly on QML stdin EOF")
    # Even CLI diagnostics/help must not contaminate the event stream.
    if argv is None:
        argv = sys.argv[1:]
    if "--help" in argv or "-h" in argv:
        parser.print_help(file=sys.stderr)
        return 0
    args = parser.parse_args(argv)
    runtime = BridgeRuntime(dev_projects=PROJECT_CONFIGS, dev_root=PROJECT_ROOT)
    server = None
    workers = []
    try:
        port = int(os.environ.get("HERMES_COUCOU_PORT", str(PORT)))
        if not 1 <= port <= 65535:
            raise ValueError("Invalid port")
        server = BridgeHTTPServer(("127.0.0.1", port), runtime, ReadEndpoints())
        runtime.emit({"event": "BridgeReady"})
        runtime.set_status(False, "Bridge ready; connecting to Hermes")
        if importlib.util.find_spec("psutil") is None:
            diagnostic("Optional dependency psutil missing; system metrics will be limited")
        for signum in (signal.SIGTERM, signal.SIGINT):
            signal.signal(signum, lambda *_: runtime.stop.set())
        workers = [threading.Thread(target=server.serve_forever, kwargs={"poll_interval": 0.1}, daemon=True),
                   threading.Thread(target=start_ws_listener_thread, args=(runtime,), daemon=True)]
        for worker in workers:
            worker.start()
        threading.Thread(target=runtime.read_stdin, args=(sys.stdin, args.stdio), daemon=True).start()
        runtime.stop.wait()
        return 0
    except Exception as exc:
        diagnostic("Bridge startup/runtime failed", exc)
        try:
            runtime.set_status(False, "Bridge unavailable: bind, runtime-directory or configuration failure")
        except (OSError, ValueError):
            pass
        return 1
    finally:
        runtime.stop.set()
        with suppress(OSError, ValueError):
            runtime.interview.stop()
        with suppress(OSError, ValueError):
            runtime.voice.stop()
        with suppress(OSError, ValueError):
            runtime.disconnected()
        if server is not None:
            if workers and workers[0].is_alive():
                server.shutdown()
            server.server_close()
        for worker in workers:
            if worker.is_alive():
                worker.join(timeout=3)


if __name__ == "__main__":
    sys.exit(main())
