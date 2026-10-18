#!/usr/bin/env python3
"""Buat efek suara QBot (linux-app/assets/sounds/*.wav) dari nada sintetis.

Tanpa dependensi: hanya modul standar. Jalankan ulang bila ingin mengubah nada.
"""
import math
import struct
import wave
from pathlib import Path

RATE = 44100
OUT = Path(__file__).resolve().parent.parent / "linux-app" / "assets" / "sounds"


def tone(freq, dur, volume=0.35, attack=0.005, decay=6.0, glide=0.0):
    """Sinus dengan attack singkat dan peluruhan eksponensial (bunyi 'ting')."""
    samples = []
    phase = 0.0
    for i in range(int(RATE * dur)):
        t = i / RATE
        f = freq + glide * t
        phase += 2 * math.pi * f / RATE
        env = min(1.0, t / attack) * math.exp(-decay * t)
        # Sedikit harmonik kedua supaya tidak terlalu 'tipis'.
        samples.append(volume * env * (math.sin(phase) + 0.18 * math.sin(2 * phase)))
    return samples


def silence(dur):
    return [0.0] * int(RATE * dur)


def mix_seq(*parts):
    out = []
    for p in parts:
        out.extend(p)
    return out


def write(name, samples):
    OUT.mkdir(parents=True, exist_ok=True)
    with wave.open(str(OUT / name), "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(RATE)
        w.writeframes(b"".join(struct.pack("<h", int(max(-1, min(1, s)) * 32767)) for s in samples))


SOUNDS = {
    # Izin/pertanyaan masuk: dua nada naik, cukup mencolok tapi pendek.
    "request.wav": mix_seq(tone(660, 0.09, decay=18), tone(990, 0.16, decay=14)),
    # Task selesai: tiga nada mayor naik (C6-E6-G6).
    "done.wav": mix_seq(tone(1047, 0.08, 0.28, decay=20), tone(1319, 0.08, 0.28, decay=20), tone(1568, 0.28, 0.3, decay=9)),
    # Task gagal: nada rendah menurun.
    "error.wav": mix_seq(tone(392, 0.12, decay=10), silence(0.02), tone(311, 0.22, decay=8, glide=-80)),
    # Pop kecil untuk task diterima.
    "pop.wav": tone(880, 0.07, 0.25, decay=40, glide=600),
}

if __name__ == "__main__":
    for filename, data in SOUNDS.items():
        write(filename, data)
        print(OUT / filename)
