#!/usr/bin/env python3
"""Kirim event demo/informatif ke bridge Coucou (localhost + token lokal).

Gunakan event non-approval untuk memicu animasi. PermissionRequest di sini
hanya tampil sebagai info karena request approval asli harus berasal dari
WebSocket Hermes.
"""
import json
import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "linux-app"))

from bridge_client import BridgeClientError, request  # noqa: E402


def main(argv):
    if len(argv) < 1:
        print("Usage: send-event.py <EventName> [JSON_STRING]", file=sys.stderr)
        return 1
    try:
        extra = json.loads(argv[1]) if len(argv) > 1 else {}
        if not isinstance(extra, dict):
            raise ValueError("JSON payload harus berupa object")
        payload = {"event": argv[0]}
        payload.update(extra)
        result = request("POST", "/event", payload)
    except (BridgeClientError, ValueError) as exc:
        print(f"Failed to send event: {exc}", file=sys.stderr)
        return 1
    print(json.dumps(result, ensure_ascii=False))
    return 0 if isinstance(result, dict) and result.get("ok") else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
