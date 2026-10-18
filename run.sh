#!/bin/bash
set -u
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Pilih interpreter untuk bridge: harus punya 'websockets' agar approval Hermes
# bisa tersambung. Utamakan HERMES_COUCOU_PYTHON, lalu python3, lalu venv Hermes.
PY="${HERMES_COUCOU_PYTHON:-python3}"
if ! "$PY" -c 'import websockets.asyncio.client' >/dev/null 2>&1; then
    for cand in "$HOME/.hermes/hermes-agent/venv/bin/python3" "$HOME/.hermes/venv/bin/python3"; do
        if [ -x "$cand" ] && "$cand" -c 'import websockets.asyncio.client' >/dev/null 2>&1; then
            PY="$cand"
            break
        fi
    done
fi

if ! "$PY" -c 'import websockets.asyncio.client' >/dev/null 2>&1; then
    echo "Coucou: modul 'websockets' tidak ditemukan - approval Hermes TIDAK akan berfungsi." >&2
    echo "  Solusi: sudo pacman -S python-websockets  (atau set HERMES_COUCOU_PYTHON ke python yang punya websockets)" >&2
fi
if ! "$PY" -c 'import psutil' >/dev/null 2>&1; then
    echo "Coucou: 'psutil' tidak ada - tab Status sistem terbatas (opsional: sudo pacman -S python-psutil)." >&2
fi
if ! command -v quickshell >/dev/null 2>&1; then
    echo "Coucou: quickshell tidak ditemukan. Install dulu (sudo pacman -S quickshell)." >&2
    exit 1
fi

export HERMES_COUCOU_PYTHON="$PY"

# Launch native Wayland Layer-shell Hermes Mochi Island via Quickshell
exec quickshell -p "$DIR/linux-app/HermesMochi.qml" "$@"
