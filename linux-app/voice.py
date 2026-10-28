"""Perintah suara QBot: "halo qbot, buka chromium dan buka youtube".

Alur: parec (mikrofon) -> Segmenter (dari interview) -> faster-whisper bahasa
Indonesia -> deteksi wake word "qbot" -> perintah diurai aturan lokal (cepat,
tanpa jaringan) atau LLM bila aturan tidak paham -> aksi dari daftar putih
dijalankan -> balasan tampil di island dan dibacakan TTS (piper / espeak-ng).

Audio tidak pernah keluar dari mesin; hanya teks perintah yang tidak dipahami
aturan lokal dikirim ke endpoint LLM. LLM tidak bisa menjalankan perintah
shell: keluarannya hanya JSON aksi yang divalidasi di sini.
"""
import configparser
import difflib
import json
import os
from pathlib import Path
import queue
import re
import shutil
import subprocess
import sys
import tempfile
import threading
import time
from urllib.parse import quote_plus, urlsplit

from interview import (FRAME_BYTES, RATE, Segmenter, WhisperTranscriber, frame_level,
                       load_llm_config, stream_answer)

FRAMES_PER_SEC = RATE * 2 // FRAME_BYTES
MAX_WAKE_SECONDS = 8       # ucapan lebih panjang saat standby bukan panggilan (hemat CPU)
AWAKE_SECONDS = 8          # setelah "halo qbot", tunggu perintah selama ini
ECHO_GUARD = 0.6           # abaikan mic sesaat setelah QBot selesai bicara
PIPER_HOME = Path.home() / ".local/share/hermes-coucou/piper"
WHISPER_PROMPT = "Halo QBot. Buka Chromium, buka YouTube, cari di Google, putar musik."

# "qbot" sering terdengar sebagai "kyu bot", "cu bot", "q-bot", "kiubot", ...
WAKE_RE = re.compile(r"\b(?:q|kyu|kiu|kiyu|kyou|cu|qu|queue|kew)\s*-?\s*(?:bot|bod|bott|but|boat|bots)\b")
SPLIT_RE = re.compile(r"\s*(?:,|\bdan\b|\blalu\b|\bterus\b|\bkemudian\b|\bsama\b|\btrus\b)\s*")

SITES = {
    "youtube": "https://www.youtube.com", "google": "https://www.google.com",
    "github": "https://github.com", "gmail": "https://mail.google.com",
    "whatsapp": "https://web.whatsapp.com", "instagram": "https://www.instagram.com",
    "facebook": "https://www.facebook.com", "twitter": "https://x.com", "x": "https://x.com",
    "netflix": "https://www.netflix.com", "google maps": "https://maps.google.com",
    "maps": "https://maps.google.com", "google drive": "https://drive.google.com",
    "drive": "https://drive.google.com", "google translate": "https://translate.google.com",
    "translate": "https://translate.google.com", "chatgpt": "https://chatgpt.com",
    "claude": "https://claude.ai", "spotify web": "https://open.spotify.com",
    "linkedin": "https://www.linkedin.com", "tiktok": "https://www.tiktok.com",
}
SITE_LABELS = {"youtube": "YouTube", "github": "GitHub", "whatsapp": "WhatsApp", "chatgpt": "ChatGPT",
               "linkedin": "LinkedIn", "tiktok": "TikTok", "x": "X"}
SEARCH_URLS = {"youtube": "https://www.youtube.com/results?search_query=",
               "google": "https://www.google.com/search?q="}
BROWSERS = ["chromium", "firefox", "google-chrome-stable", "brave", "zen-browser", "vivaldi-stable"]
MEDIA = {"play-pause", "next", "previous"}
VOLUME = {"up": "volume_up", "down": "volume_down", "mute": "volume_mute"}

SYSTEM_PROMPT = """Kamu QBot, asisten suara di desktop Linux pengguna. Kamu menerima
perintah lisan (hasil speech-to-text, bisa ada salah dengar) dan membalas HANYA
satu objek JSON tanpa teks lain:

{"reply": "<balasan singkat, ramah, bahasa Indonesia, maks 2 kalimat>",
 "actions": [<aksi>, ...]}

Aksi yang tersedia (hanya ini, jangan mengarang aksi lain):
- {"type": "open_app", "app": "<nama aplikasi, mis. chromium, code, kitty, spotify>"}
- {"type": "open_url", "url": "https://...", "browser": "<opsional: chromium|firefox|...>"}
- {"type": "search", "engine": "youtube|google", "query": "<kata kunci>", "browser": "<opsional>"}
- {"type": "media", "name": "play-pause|next|previous"}
- {"type": "volume", "name": "up|down|mute"}
- {"type": "screenshot"}

Aturan:
- Bila pengguna minta membuka situs DI browser tertentu, pakai open_url dengan field
  browser; jangan tambahkan open_app untuk browser itu.
- Pertanyaan atau obrolan biasa: actions kosong, jawab di reply.
- Permintaan yang tidak bisa dilakukan dengan aksi di atas (hapus file, kirim pesan,
  matikan komputer, dsb.): actions kosong, jelaskan singkat di reply.
- reply harus enak dibacakan suara: tanpa emoji, tanpa markdown, tanpa URL.
"""


def diagnostic(message, exc=None):
    suffix = " (" + type(exc).__name__ + ": " + str(exc)[:200] + ")" if exc else ""
    print("voice: " + message + suffix, file=sys.stderr, flush=True)


def normalize(text):
    text = text.lower().replace("-", " ")
    text = re.sub(r"[^\w\s.]", " ", text)
    return re.sub(r"\s+", " ", text).strip(" .")


def split_wake(text):
    """(dipanggil?, sisa perintah setelah nama QBot)."""
    norm = normalize(text)
    match = WAKE_RE.search(norm)
    if not match:
        return False, ""
    return True, norm[match.end():].strip(" .")


class DesktopApps:
    """Aplikasi dari file .desktop (yang tampil di launcher), dicocokkan longgar."""
    def __init__(self, dirs=None):
        data_dirs = os.environ.get("XDG_DATA_DIRS", "/usr/local/share:/usr/share").split(":")
        self.dirs = dirs or ([Path.home() / ".local/share/applications",
                              Path.home() / ".local/share/flatpak/exports/share/applications",
                              Path("/var/lib/flatpak/exports/share/applications")]
                             + [Path(d) / "applications" for d in data_dirs if d])
        self.apps = None
        self.loaded_at = 0.0

    def scan(self):
        apps = {}
        for directory in self.dirs:
            try:
                files = sorted(directory.glob("*.desktop"))
            except OSError:
                continue
            for path in files:
                if path.stem in apps:
                    continue   # direktori pertama (pengguna) menang
                parser = configparser.ConfigParser(interpolation=None, strict=False)
                try:
                    parser.read(path, encoding="utf-8")
                    entry = parser["Desktop Entry"]
                except (configparser.Error, KeyError, OSError, UnicodeError):
                    continue
                if entry.get("Type") != "Application" or entry.get("NoDisplay", "").lower() == "true":
                    continue
                exec_name = Path((entry.get("Exec") or "").split(" ")[0]).name
                names = {normalize(entry.get("Name", "")), normalize(path.stem.split(".")[-1]),
                         normalize(exec_name)}
                names |= {normalize(k) for k in (entry.get("Keywords") or "").split(";") if k.strip()}
                apps[path.stem] = {"id": path.stem, "name": entry.get("Name", path.stem),
                                   "names": {n for n in names if n}}
        return apps

    def find(self, query):
        if self.apps is None or time.monotonic() - self.loaded_at > 60:
            self.apps, self.loaded_at = self.scan(), time.monotonic()
        query = normalize(query)
        if not query:
            return None
        for app in self.apps.values():
            if query in app["names"]:
                return app
        by_name = {name: app for app in self.apps.values() for name in app["names"]}
        close = difflib.get_close_matches(query, list(by_name), n=1, cutoff=0.8)
        return by_name[close[0]] if close else None


class Speaker:
    """TTS: piper (suara natural, lokal) -> espeak-ng -> diam."""
    def __init__(self):
        self.piper = self._find_piper()
        self.voice = self._find_voice()
        if self.piper and self.voice:
            self.backend = "piper"
        elif shutil.which("espeak-ng"):
            self.backend = "espeak"
        else:
            self.backend = "none"

    @staticmethod
    def _find_piper():
        candidates = [os.environ.get("HERMES_COUCOU_PIPER", ""), str(PIPER_HOME / "venv/bin/piper"),
                      shutil.which("piper") or "", shutil.which("piper-tts") or ""]
        return next((c for c in candidates if c and os.access(c, os.X_OK)), None)

    @staticmethod
    def _find_voice():
        configured = os.environ.get("HERMES_COUCOU_PIPER_VOICE", "")
        if configured and Path(configured).is_file():
            return configured
        voices = sorted((PIPER_HOME / "voices").glob("*.onnx"))
        return str(voices[0]) if voices else None

    def say(self, text):
        if not text or self.backend == "none" or not shutil.which("pw-play"):
            return
        try:
            if self.backend == "piper":
                fd, wav = tempfile.mkstemp(prefix="qbot-voice-", suffix=".wav")
                os.close(fd)
                try:
                    subprocess.run([self.piper, "-m", self.voice, "-f", wav], input=text, text=True,
                                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=30, check=True)
                    subprocess.run(["pw-play", wav], stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                                   stderr=subprocess.DEVNULL, timeout=60)
                finally:
                    os.unlink(wav)
            else:
                subprocess.run(["espeak-ng", "-v", "id", "-s", "165", text], stdin=subprocess.DEVNULL,
                               stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=60)
        except (OSError, subprocess.SubprocessError) as exc:
            diagnostic("TTS gagal", exc)


class VoiceTranscriber(WhisperTranscriber):
    def __init__(self):
        super().__init__(model=os.environ.get("HERMES_COUCOU_VOICE_WHISPER", "small"),
                         language=os.environ.get("HERMES_COUCOU_VOICE_LANG", "id"))

    def __call__(self, pcm):
        import numpy as np
        self.load()
        audio = np.frombuffer(pcm, dtype=np.int16).astype(np.float32) / 32768.0
        segments, _ = self.model.transcribe(audio, language=self.language, beam_size=1, vad_filter=True,
                                            condition_on_previous_text=False, initial_prompt=WHISPER_PROMPT)
        return " ".join(s.text.strip() for s in segments if s.no_speech_prob < 0.6).strip()


class CommandParser:
    """Aturan lokal untuk perintah umum; None bila ada bagian yang tidak dipahami."""
    def __init__(self, apps):
        self.apps = apps

    def parse(self, text):
        clauses = [c for c in SPLIT_RE.split(normalize(text)) if c]
        if not clauses:
            return None
        actions = []
        for clause in clauses:
            action = self.clause(clause)
            if action is None:
                return None
            actions.append(action)
        return actions

    def clause(self, text):
        text = re.sub(r"^(?:tolong|coba|dong|qbot|bisa|please)\s+", "", text)
        text = re.sub(r"\s+(?:dong|ya|yah|deh|please|sekarang)$", "", text)
        if re.search(r"\bjam berapa\b|\bpukul berapa\b", text):
            return {"type": "time"}
        if re.search(r"screenshot|tangkap layar|potret layar", text):
            return {"type": "screenshot"}
        if re.search(r"\b(?:naik(?:kan)?|besar(?:kan)?|keras(?:kan)?)\b.*\b(?:volume|suara)\b|\bvolume\b.*\b(?:naik|besar)", text):
            return {"type": "volume", "name": "up"}
        if re.search(r"\b(?:turun(?:kan)?|kecil(?:kan)?|pelan(?:kan)?)\b.*\b(?:volume|suara)\b|\bvolume\b.*\b(?:turun|kecil)", text):
            return {"type": "volume", "name": "down"}
        if re.search(r"\b(?:bisukan|mute|matikan suara)\b", text):
            return {"type": "volume", "name": "mute"}
        if re.search(r"\b(?:lagu|musik)\b.*\b(?:berikutnya|selanjutnya|lanjut)\b|^(?:next|skip)\b", text):
            return {"type": "media", "name": "next"}
        if re.search(r"\b(?:lagu|musik)\b.*\bsebelumnya\b|^previous\b", text):
            return {"type": "media", "name": "previous"}
        if re.fullmatch(r"(?:jeda|pause|stop|hentikan|putar|play|lanjutkan)(?: (?:musik|lagu))?", text):
            return {"type": "media", "name": "play-pause"}
        match = re.fullmatch(r"(?:cari(?:kan)?|search|putar(?:kan)?|play|setel)\s+(.+?)\s+(?:di|pakai|lewat)\s+(youtube|google)", text)
        if match:
            return {"type": "search", "engine": match.group(2), "query": match.group(1)}
        match = re.fullmatch(r"(?:cari(?:kan)?|search|googling)\s+(.+)", text)
        if match:
            return {"type": "search", "engine": "google", "query": match.group(1)}
        match = re.fullmatch(r"(?:buka(?:kan|in)?|jalankan|open|launch)\s+(.+)", text)
        if not match:
            return None
        target = re.sub(r"^(?:aplikasi|app|situs|website|web)\s+", "", match.group(1))
        browser = None
        on_browser = re.fullmatch(r"(.+?)\s+(?:di|pakai|lewat)\s+(\w+)", target)
        if on_browser and on_browser.group(2) in BROWSERS:
            target, browser = on_browser.group(1), on_browser.group(2)
        if target in SITES:
            return {"type": "open_url", "url": SITES[target], "browser": browser}
        if re.fullmatch(r"[\w-]+(?:\.[\w-]+)+(?:/\S*)?", target):
            return {"type": "open_url", "url": "https://" + target, "browser": browser}
        if self.apps.find(target):
            return {"type": "open_app", "app": target}
        return None


class VoiceAssistant:
    def __init__(self, emit, launcher, transcriber=None, llm=None, capture=None, speaker=None, apps=None):
        self.emit = emit
        self.launcher = launcher
        self.transcriber = transcriber or VoiceTranscriber()
        self.llm = llm or (lambda messages: stream_answer(load_llm_config(), messages))
        self.capture = capture or self._parec
        self.speaker = speaker
        self.apps = apps or DesktopApps()
        self.parser = CommandParser(self.apps)
        self.lock = threading.RLock()
        self.proc = None
        self.session = 0
        self.state = "off"
        self.message = ""
        self.awake_until = 0.0
        self.deaf_until = 0.0     # gema suara QBot sendiri jangan dianggap perintah
        self.segments = queue.Queue(maxsize=4)
        self.history = []          # beberapa giliran terakhir untuk obrolan

    # ---------- status ----------

    def _status(self, state, message=""):
        self.state, self.message = state, message
        self.emit({"event": "VoiceStatus", "state": state, "message": message,
                   "tts": self.speaker.backend if self.speaker else ""})

    def emit_status(self):
        with self.lock:
            self._status(self.state, self.message)

    @staticmethod
    def _parec():
        if shutil.which("parec") is None:
            raise ValueError("parec tidak ditemukan (pasang pipewire-pulse / libpulse)")
        return subprocess.Popen(["parec", "--device=@DEFAULT_SOURCE@", "--format=s16le", "--rate=%d" % RATE,
                                 "--channels=1", "--latency-msec=60", "--client-name=hermes-coucou-voice"],
                                stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)

    # ---------- perintah dari island ----------

    def start(self):
        with self.lock:
            if self.proc is not None:
                return "Perintah suara sudah aktif"
            self.session += 1
            session = self.session
            self.segments = queue.Queue(maxsize=4)
            self.proc = self.capture()
            self._status("loading", "Memuat model Whisper…")
        threading.Thread(target=self._read_loop, args=(session, self.proc, self.segments), daemon=True).start()
        threading.Thread(target=self._worker, args=(session, self.segments), daemon=True).start()
        return "Perintah suara aktif — panggil \"halo qbot\""

    def stop(self):
        with self.lock:
            if self.proc is None:
                self._status("off")
                return "Perintah suara sudah mati"
            self._stop_locked()
            self._status("off")
        return "Perintah suara mati"

    def _stop_locked(self):
        self.session += 1
        proc, self.proc = self.proc, None
        if proc is not None:
            proc.terminate()
            try:
                proc.wait(timeout=2)
            except subprocess.TimeoutExpired:
                proc.kill()
        try:
            self.segments.put_nowait(None)
        except queue.Full:
            pass

    def run_text(self, text):
        """Perintah ketik (tanpa wake word) — juga dipakai untuk menguji tanpa mikrofon."""
        if not isinstance(text, str) or not text.strip() or len(text) > 500:
            raise ValueError("Perintah kosong atau terlalu panjang")
        threading.Thread(target=self._handle_command, args=(text.strip(),), daemon=True).start()
        return "Memproses perintah…"

    # ---------- pipeline ----------

    def _alive(self, session):
        return self.session == session

    def _read_loop(self, session, proc, segments):
        segmenter = Segmenter()
        try:
            while self._alive(session):
                frame = proc.stdout.read(FRAME_BYTES)
                if not frame or len(frame) < FRAME_BYTES:
                    break
                segment = segmenter.feed(frame, frame_level(frame))
                if segment is None or time.monotonic() < self.deaf_until or self.state not in ("standby", "awake"):
                    continue
                awake = self.state == "awake"
                if not awake and len(segment) > MAX_WAKE_SECONDS * FRAMES_PER_SEC * FRAME_BYTES:
                    continue
                try:
                    segments.put_nowait(segment)
                except queue.Full:
                    pass
        except (OSError, ValueError) as exc:
            diagnostic("Capture mikrofon gagal", exc)
        with self.lock:
            if self._alive(session):
                self._stop_locked()
                self._status("error", "Mikrofon berhenti tiba-tiba (cek PipeWire/perangkat)")

    def _worker(self, session, segments):
        try:
            self.transcriber.load()
            if self.speaker is None:
                self.speaker = Speaker()
        except Exception as exc:   # ImportError, unduhan model, ctranslate2
            diagnostic("Whisper gagal dimuat", exc)
            with self.lock:
                if self._alive(session):
                    self._stop_locked()
                    self._status("error", "Whisper gagal dimuat: pastikan faster-whisper terpasang di python bridge")
            return
        with self.lock:
            if not self._alive(session):
                return
            self._status("standby", "Panggil \"halo qbot\"")
        while True:
            try:
                segment = segments.get(timeout=0.5)
            except queue.Empty:
                if self.state == "awake" and time.monotonic() > self.awake_until and self._alive(session):
                    self._status("standby", "Panggil \"halo qbot\"")
                continue
            if segment is None or not self._alive(session):
                return
            try:
                text = self.transcriber(segment)
            except Exception as exc:
                diagnostic("Transkripsi gagal", exc)
                continue
            if text and self._alive(session):
                self._on_speech(text)

    def _on_speech(self, text):
        called, rest = split_wake(text)
        if self.state == "awake":
            self._handle_command(rest if called and rest else text)
        elif called:
            if len(rest.split()) >= 2:
                self._handle_command(rest)
            else:
                self._status("awake", "Ya? Aku dengar…")
                self.emit({"event": "VoiceHeard", "text": text, "wake": True})
                self._speak("Ya?")
                self.awake_until = time.monotonic() + AWAKE_SECONDS
        self._drain()

    def _drain(self):
        """Buang ucapan yang menumpuk selama QBot berpikir atau bicara."""
        try:
            while True:
                item = self.segments.get_nowait()
                if item is None:
                    self.segments.put_nowait(None)
                    return
        except queue.Empty:
            pass

    def _speak(self, text):
        if self.speaker is None:
            self.speaker = Speaker()
        self.deaf_until = float("inf")
        try:
            self.speaker.say(text)
        finally:
            self.deaf_until = time.monotonic() + ECHO_GUARD

    def _handle_command(self, text):
        listening = self.proc is not None
        self.emit({"event": "VoiceHeard", "text": text, "wake": False})
        self._status("thinking", text)
        actions = self.parser.parse(text)
        reply = None
        if actions is None:
            try:
                reply, actions = self._ask_llm(text)
            except Exception as exc:
                diagnostic("LLM gagal", exc)
                reply, actions = "Maaf, aku belum paham perintah itu.", []
                self._finish(text, reply, False, listening)
                return
        ok, done, errors = True, [], []
        for action in self._merge_browser(actions):
            try:
                done.append(self._execute(action))
            except (ValueError, OSError, subprocess.SubprocessError) as exc:
                ok = False
                errors.append(str(exc) or type(exc).__name__)
        if reply is None:
            reply = self._describe(done) if done else "Hmm, tidak ada yang bisa kulakukan."
        if errors:
            reply = (reply + " " if done else "") + "Tapi ada yang gagal: " + errors[0]
        self._finish(text, reply, ok, listening)

    def _finish(self, text, reply, ok, listening):
        self.history = (self.history + [{"role": "user", "content": text},
                                        {"role": "assistant", "content": reply}])[-8:]
        self.emit({"event": "VoiceReply", "text": reply, "ok": ok})
        if listening:
            self._status("speaking", reply)
        self._speak(reply)
        with self.lock:
            if self.proc is not None:
                self._status("standby", "Panggil \"halo qbot\"")
            elif not listening:
                self._status(self.state if self.state != "thinking" else "off")

    def _ask_llm(self, text):
        now = time.strftime("%A %d %B %Y, %H:%M")
        messages = ([{"role": "system", "content": SYSTEM_PROMPT + "\nWaktu sekarang: " + now}]
                    + self.history + [{"role": "user", "content": text}])
        raw = "".join(self.llm(messages)).strip()
        match = re.search(r"\{.*\}", raw, re.DOTALL)
        if not match:
            return raw[:300] or "Maaf, aku tidak menangkap maksudnya.", []
        data = json.loads(match.group(0))
        reply = str(data.get("reply") or "").strip()[:300]
        actions = [a for a in (data.get("actions") or []) if isinstance(a, dict)][:5]
        return reply or None, actions

    def _merge_browser(self, actions):
        """'buka chromium dan buka youtube' = YouTube di Chromium, bukan dua jendela."""
        out = []
        for action in actions:
            prev = out[-1] if out else None
            if (prev and prev.get("type") == "open_app" and normalize(str(prev.get("app"))) in BROWSERS
                    and action.get("type") in ("open_url", "search") and not action.get("browser")):
                out[-1] = dict(action, browser=normalize(str(prev.get("app"))))
            else:
                out.append(action)
        return out

    def _browser(self, name):
        if not name:
            return None
        name = normalize(str(name)).replace(" ", "-")
        name = {"chrome": "google-chrome-stable", "google-chrome": "google-chrome-stable"}.get(name, name)
        if name not in BROWSERS:
            raise ValueError("Browser " + name + " tidak didukung")
        if not shutil.which(name):
            raise ValueError(name + " tidak terpasang")
        return name

    def _open_url(self, url, browser):
        parsed = urlsplit(url)
        if parsed.scheme not in ("http", "https") or not parsed.hostname or parsed.username or parsed.password:
            raise ValueError("URL tidak valid")
        browser = self._browser(browser)
        if browser:
            self.launcher.spawn([browser, url])
        else:
            self.launcher.launch({"name": "open_url", "url": url})

    def _execute(self, action):
        kind = action.get("type")
        if kind == "open_app":
            app = self.apps.find(str(action.get("app") or ""))
            if not app:
                raise ValueError("Aplikasi " + str(action.get("app")) + " tidak ditemukan")
            self.launcher.spawn(["gtk-launch", app["id"]])
            return "membuka " + app["name"]
        if kind == "open_url":
            url = str(action.get("url") or "")
            self._open_url(url, action.get("browser"))
            host = urlsplit(url).hostname or url
            site = next((name for name, site in SITES.items() if urlsplit(site).hostname == host), None)
            label = SITE_LABELS.get(site, site.title()) if site else host
            return "membuka " + label + (" di " + action["browser"].title() if action.get("browser") else "")
        if kind == "search":
            engine = action.get("engine") if action.get("engine") in SEARCH_URLS else "google"
            query = str(action.get("query") or "").strip()[:200]
            if not query:
                raise ValueError("Kata kunci pencarian kosong")
            self._open_url(SEARCH_URLS[engine] + quote_plus(query), action.get("browser"))
            return "mencari " + query + " di " + SITE_LABELS.get(engine, engine.title())
        if kind == "media":
            if action.get("name") not in MEDIA:
                raise ValueError("Aksi media tidak dikenal")
            self.launcher.media(action["name"])
            return {"play-pause": "memutar atau menjeda musik", "next": "memutar lagu berikutnya",
                    "previous": "memutar lagu sebelumnya"}[action["name"]]
        if kind == "volume":
            if action.get("name") not in VOLUME:
                raise ValueError("Aksi volume tidak dikenal")
            self.launcher.launch({"name": VOLUME[action["name"]]})
            return {"up": "menaikkan volume", "down": "menurunkan volume", "mute": "membisukan suara"}[action["name"]]
        if kind == "screenshot":
            self.launcher.launch({"name": "screenshot"})
            return "mengambil screenshot"
        if kind == "time":
            return "jam " + time.strftime("%H.%M")
        raise ValueError("Aksi " + str(kind) + " tidak didukung")

    @staticmethod
    def _describe(done):
        if len(done) == 1 and done[0].startswith("jam "):
            return "Sekarang " + done[0] + "."
        opened = " dan ".join(done) if len(done) <= 2 else ", ".join(done[:-1]) + ", dan " + done[-1]
        return "Siap, " + opened + "."
