#!/usr/bin/env python3
"""Small authenticated bridge client (stdlib only).

request() returns decoded JSON, and raises BridgeClientError on failure. The CLI
always writes one JSON line, including on errors. Never pass the token on argv.
"""
import json
import os
from pathlib import Path
import stat
import sys
import tempfile
import urllib.error
import urllib.request

MAX_BODY = 256 * 1024


class BridgeClientError(RuntimeError):
    pass


def runtime_directory():
    runtime = os.environ.get("XDG_RUNTIME_DIR")
    if runtime:
        base = Path(runtime)
        if not base.is_absolute():
            raise BridgeClientError("XDG_RUNTIME_DIR must be absolute")
        info = base.lstat()
        if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o077:
            raise BridgeClientError("Unsafe XDG_RUNTIME_DIR")
        return base / "hermes-coucou"
    return Path(tempfile.gettempdir()) / ("hermes-coucou-" + str(os.getuid()))


def read_token():
    directory = runtime_directory()
    info = directory.lstat()
    if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o077:
        raise BridgeClientError("Unsafe bridge runtime directory")
    fd = os.open(directory / "bridge.token", os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    with os.fdopen(fd, "r", encoding="ascii") as stream:
        info = os.fstat(stream.fileno())
        if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o077:
            raise BridgeClientError("Unsafe bridge token file")
        token = stream.read(129).strip()
    if len(token) != 64 or any(c not in "0123456789abcdef" for c in token):
        raise BridgeClientError("Invalid bridge token file")
    return token


def request(method, path, payload=None, timeout=35):
    method = method.upper()
    if method not in ("GET", "POST") or not isinstance(path, str) or not path.startswith("/"):
        raise BridgeClientError("Use GET or POST with a local /path")
    if path.startswith("//") or any(c in path for c in "?#\r\n"):
        raise BridgeClientError("Invalid bridge path")
    try:
        port = int(os.environ.get("HERMES_COUCOU_PORT", "4848"))
        if not 1 <= port <= 65535:
            raise ValueError()
        data = None if payload is None else json.dumps(payload, allow_nan=False).encode("utf-8")
        if data is not None and len(data) > MAX_BODY:
            raise BridgeClientError("Request body too large")
        req = urllib.request.Request(
            f"http://127.0.0.1:{port}{path}", data=data, method=method,
            headers={"Authorization": "Bearer " + read_token(), "Content-Type": "application/json"},
        )
        # Do not send the local credential through an environment-configured proxy
        # or follow redirects to another server.
        class NoRedirect(urllib.request.HTTPRedirectHandler):
            def redirect_request(self, *args, **kwargs):
                return None

        opener = urllib.request.build_opener(urllib.request.ProxyHandler({}), NoRedirect())
        with opener.open(req, timeout=timeout) as response:
            raw = response.read(MAX_BODY + 1)
        if len(raw) > MAX_BODY:
            raise BridgeClientError("Bridge response too large")
        result = json.loads(raw)
        if isinstance(result, dict) and result.get("ok") is False:
            raise BridgeClientError(result.get("message", "Bridge rejected request"))
        return result
    except urllib.error.HTTPError as exc:
        raise BridgeClientError(f"Bridge HTTP error {exc.code}") from None
    except BridgeClientError:
        raise
    except (OSError, ValueError, urllib.error.URLError):
        raise BridgeClientError("Bridge unavailable or invalid response/configuration") from None


def main(argv=None):
    args = sys.argv[1:] if argv is None else argv
    try:
        if len(args) not in (2, 3) or args[0] not in ("get", "post"):
            raise BridgeClientError("Usage: bridge_client.py get /path | post /path '<JSON>'")
        if (args[0] == "get" and len(args) != 2) or (args[0] == "post" and len(args) != 3):
            raise BridgeClientError("GET takes no body; POST requires a JSON body")
        payload = json.loads(args[2]) if len(args) == 3 else None
        result = request(args[0], args[1], payload)
        print(json.dumps(result, ensure_ascii=True, separators=(",", ":"), allow_nan=False))
        return 0
    except (BridgeClientError, ValueError) as exc:
        message = str(exc) if isinstance(exc, BridgeClientError) else "Invalid JSON body"
        print(json.dumps({"ok": False, "message": message}, separators=(",", ":")))
        print(message, file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
