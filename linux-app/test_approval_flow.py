#!/usr/bin/env python3
"""Event approval demo: tampil sebagai info di island, tanpa tombol.

Request approval asli hanya datang dari WebSocket Hermes; event ini tidak
mengirim keputusan apa pun ke sesi yang sedang berjalan.
"""
import json
import sys

from bridge_client import BridgeClientError, request


def trigger(payload):
    try:
        result = request("POST", "/event", payload)
    except (BridgeClientError, ValueError) as exc:
        print("Failed:", exc, file=sys.stderr)
        return 1
    print(json.dumps(result, ensure_ascii=False))
    return 0 if isinstance(result, dict) and result.get("ok") else 1


if __name__ == "__main__":
    if len(sys.argv) > 1 and sys.argv[1] == "done":
        sys.exit(trigger({
            "event": "StopSuccess",
            "message": "Task telah selesai dilakukan dengan sukses!"
        }))
    sys.exit(trigger({
        "event": "PermissionRequest",
        "tool_name": "terminal",
        "message": "Dangerous command: rm -rf /tmp/demo_test"
    }))
