#!/usr/bin/env python3
import sys
import json
import urllib.request

if __name__ == "__main__":
    prompt = sys.argv[1] if len(sys.argv) > 1 else ""
    image_path = sys.argv[2] if len(sys.argv) > 2 else ""
    
    data = json.dumps({"prompt": prompt, "image_path": image_path}).encode("utf-8")
    req = urllib.request.Request(
        "http://127.0.0.1:4848/chat",
        data=data,
        headers={"Content-Type": "application/json"},
        method="POST"
    )
    try:
        with urllib.request.urlopen(req, timeout=5) as resp:
            pass
    except Exception as e:
        print("Chat send error:", e)
