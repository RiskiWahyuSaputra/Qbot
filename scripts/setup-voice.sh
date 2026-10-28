#!/usr/bin/env bash
# Pasang TTS piper (venv terpisah, tidak menyentuh venv Hermes) + suara Indonesia
# untuk balasan suara QBot. Tanpa ini QBot memakai espeak-ng, atau hanya teks.
set -euo pipefail
DIR="$HOME/.local/share/hermes-coucou/piper"
VOICE="${1:-id/id_ID/news_tts/medium/id_ID-news_tts-medium}"
URL="https://huggingface.co/rhasspy/piper-voices/resolve/main/$VOICE.onnx"
mkdir -p "$DIR/voices"
if [ ! -x "$DIR/venv/bin/piper" ]; then
    uv venv -q -p 3.11 "$DIR/venv"
    uv pip install -q -p "$DIR/venv/bin/python" piper-tts
fi
name="$(basename "$VOICE")"
[ -f "$DIR/voices/$name.onnx" ] || curl -fL -o "$DIR/voices/$name.onnx" "$URL"
[ -f "$DIR/voices/$name.onnx.json" ] || curl -fL -o "$DIR/voices/$name.onnx.json" "$URL.json"
echo "Halo, aku QBot." | "$DIR/venv/bin/piper" -m "$DIR/voices/$name.onnx" -f /dev/stdout 2>/dev/null | pw-play - \
    && echo "Piper siap: $DIR"
