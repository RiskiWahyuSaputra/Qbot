#!/usr/bin/env python3
"""Munculkan kartu izin / pertanyaan contoh di island, lalu cetak jawabanmu.

    ./test-request.py izin              kartu izin (Tolak / Selalu izinkan / Izinkan)
    ./test-request.py pertanyaan        satu pertanyaan single-select
    ./test-request.py multi             dua pertanyaan: single-select + multi-select
    ./test-request.py bebas             pertanyaan tanpa pilihan (ketik jawaban)
    ./test-request.py semua             semuanya sekaligus (uji antrean 1/N)

Opsi: --agent claude|opencode (logo di kartu, default claude), --tunggu DETIK
(default 120). Ini hanya uji tampilan & alur klik: tidak ada perintah yang
benar-benar dijalankan dan tidak ada agent yang menerima jawabannya.
"""
import argparse
import json
import os
import sys
import threading

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "linux-app"))

from bridge_client import BridgeClientError, request  # noqa: E402

SAMPLES = {
    "izin": {
        "kind": "permission", "title": "Izinkan Bash?", "can_always": True,
        "detail": "Bash: git push origin staging && php artisan migrate --force",
    },
    "pertanyaan": {
        "kind": "question",
        "questions": [{
            "question": "Database mana yang dipakai untuk fitur laporan?", "header": "Database",
            "options": [
                {"label": "PostgreSQL", "description": "Sudah dipakai di best-cso, dukung JSONB"},
                {"label": "SQLite", "description": "Ringan, cocok untuk pengembangan lokal"},
                {"label": "MySQL", "description": "Sama seperti server produksi lama"},
            ],
        }],
    },
    "multi": {
        "kind": "question",
        "questions": [
            {"question": "Rilis ke mana dulu?", "header": "Target",
             "options": [{"label": "Staging", "description": "cso.brilian.dev"},
                         {"label": "Production", "description": "cso.best-operational.id"}]},
            {"question": "Fitur apa saja yang ikut dirilis?", "header": "Fitur", "multiSelect": True,
             "options": [{"label": "Export PDF"}, {"label": "Filter tanggal"}, {"label": "Grafik bulanan"}]},
        ],
    },
    "bebas": {
        "kind": "question",
        "questions": [{"question": "Nama branch untuk fitur ini?", "header": "Branch", "options": []}],
    },
}


def ask(name, agent, wait, lock):
    payload = {"agent": agent, "request_id": "demo-" + name + "-" + os.urandom(4).hex(),
               "project": "demo-coucou", "timeout": wait, **SAMPLES[name]}
    try:
        result = request("POST", "/agent/request", payload, timeout=wait + 10)
    except BridgeClientError as exc:
        result = {"status": "gagal", "answer": str(exc)}
    with lock:
        status = result.get("status")
        answer = result.get("answer")
        if status == "answered" and answer and answer.get("decision") == "terminal":
            print(f"[{name}] kamu memilih: Jawab di terminal")
        elif status == "answered":
            print(f"[{name}] jawaban diterima: {json.dumps(answer, ensure_ascii=False)}")
        else:
            label = {"timeout": "waktu habis", "cancelled": "dibatalkan"}.get(status, status)
            print(f"[{name}] tidak dijawab ({label})" + (f": {answer}" if answer else ""))


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("jenis", choices=[*SAMPLES, "semua"])
    parser.add_argument("--agent", choices=["claude", "opencode"], default="claude")
    parser.add_argument("--tunggu", type=int, default=120)
    args = parser.parse_args()
    names = list(SAMPLES) if args.jenis == "semua" else [args.jenis]
    print(f"Kartu {', '.join(names)} dikirim ke island. Jawab di sana (menunggu {args.tunggu} dtk)…")
    lock = threading.Lock()
    threads = [threading.Thread(target=ask, args=(n, args.agent, args.tunggu, lock)) for n in names]
    for t in threads:
        t.start()
        t.join(0.3)  # urutan antrean di island mengikuti urutan di atas
    for t in threads:
        t.join()
    return 0


if __name__ == "__main__":
    sys.exit(main())
