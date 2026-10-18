"""Asisten interview: dengar lawan bicara, transkrip, lalu sarankan jawaban.

Alur: parec (PipeWire/Pulse) -> segmentasi energi (Segmenter) -> faster-whisper
-> transkrip ke island -> setelah lawan bicara diam sebentar, LLM
(OpenAI-compatible, default endpoint & model dari ~/.hermes/config.yaml)
menulis saran jawaban secara streaming.

Sumber "system" merekam monitor output (suara dari Zoom/Meet di speaker/
headset), "mic" merekam mikrofon (interview tatap muka). Profil/CV untuk
konteks jawaban ada di ~/.config/hermes-coucou/interview_profile.md.
Semua proses lokal kecuali permintaan ke endpoint LLM.
"""
import json
import os
from pathlib import Path
import queue
import re
import shutil
import subprocess
import sys
import threading
import time
import urllib.error
import urllib.request

RATE = 16000
FRAME = 480                 # 30 ms @ 16 kHz, s16le mono
FRAME_BYTES = FRAME * 2
PREROLL_FRAMES = 10         # 300 ms sebelum suara pertama ikut direkam
END_SILENCE_FRAMES = 27     # ~0.8 dtk hening = akhir kalimat
MIN_SPEECH_FRAMES = 13      # < ~0.4 dtk suara dianggap noise
MAX_SEGMENT_FRAMES = 500    # potong paksa tiap 15 dtk agar transkrip tetap mengalir
ANSWER_DELAY = 0.8          # jeda setelah transkrip terakhir sebelum menjawab
MAX_CONTEXT_LINES = 40
PROFILE_LIMIT = 12000
SOURCES = {"system": "@DEFAULT_MONITOR@", "mic": "@DEFAULT_SOURCE@"}
# Di 9router, combo default Hermes (reasoning + fallback) butuh ~6-7 dtk sampai
# token pertama; model flash ini ~2 dtk. Combo tetap dipakai sebagai cadangan.
FAST_MODEL_9ROUTER = "ag/gemini-3.8-flash-low"

PROFILE_PATH = Path.home() / ".config/hermes-coucou/interview_profile.md"
LOG_DIR = Path.home() / ".local/share/hermes-coucou/interviews"
PROFILE_TEMPLATE = """# Profil Interview

Isi file ini supaya saran jawaban sesuai dirimu. Semakin spesifik semakin bagus.

## Posisi yang dilamar
- Perusahaan:
- Posisi:
- Deskripsi pekerjaan (tempel di sini):

## Tentang saya
- Nama:
- Pengalaman kerja (perusahaan, peran, tahun, pencapaian berangka):
- Proyek unggulan:
- Skill / tech stack:
- Pendidikan:

## Cerita STAR siap pakai
- Konflik di tim:
- Kegagalan & pelajaran:
- Pencapaian terbesar:

## Preferensi
- Ekspektasi gaji:
- Kapan bisa mulai:
- Gaya jawaban: singkat, percaya diri, jujur
"""

SYSTEM_PROMPT = """Kamu asisten real-time untuk kandidat yang sedang interview kerja.
Kamu menerima transkrip ucapan PEWAWANCARA (hasil speech-to-text, bisa ada salah dengar)
dan profil kandidat. Tulis saran jawaban yang bisa langsung diucapkan kandidat.

Aturan:
- Jawab dalam bahasa yang sama dengan pertanyaan pewawancara.
- Sudut pandang orang pertama ("saya"/"I"), natural untuk diucapkan, tidak kaku.
- Format: 1 kalimat inti di baris pertama, lalu 2-4 poin pendek diawali "- ".
- Gunakan fakta dari profil. Jangan mengarang pengalaman, angka, atau nama perusahaan
  yang tidak ada di profil; bila profil tidak memuatnya, beri kerangka jawaban
  dengan [isi: ...] sebagai tempat kandidat mengisi.
- Pertanyaan teknis: jawab benar dan ringkas, sertakan istilah kunci.
- Pertanyaan perilaku: gunakan pola STAR secara singkat.
- Bila ucapan terakhir bukan pertanyaan dan tidak perlu ditanggapi (basa-basi,
  "oke", pewawancara masih menjelaskan), balas persis: SKIP
"""


def diagnostic(message, exc=None):
    suffix = " (" + type(exc).__name__ + ": " + str(exc)[:200] + ")" if exc else ""
    print("interview: " + message + suffix, file=sys.stderr, flush=True)


def frame_level(frame):
    """RMS ternormalisasi 0..1 untuk satu frame s16le."""
    import numpy as np
    samples = np.frombuffer(frame, dtype=np.int16).astype(np.float32) / 32768.0
    return float(np.sqrt(np.mean(samples * samples))) if samples.size else 0.0


class Segmenter:
    """Potong aliran audio jadi segmen ucapan berdasarkan energi.

    Noise floor diperkirakan dari frame hening (EMA) supaya bekerja di ruangan
    berisik maupun sunyi. feed() mengembalikan bytes segmen yang selesai.
    """
    def __init__(self, min_threshold=0.006, ratio=2.5):
        self.min_threshold = min_threshold
        self.ratio = ratio
        self.noise = min_threshold / ratio
        self.preroll = []
        self.frames = []
        self.speech = 0
        self.silence = 0
        self.active = False

    def threshold(self):
        return max(self.min_threshold, self.noise * self.ratio)

    def feed(self, frame, level):
        voiced = level > self.threshold()
        if not self.active:
            if not voiced:
                self.noise = 0.95 * self.noise + 0.05 * level
                self.preroll = (self.preroll + [frame])[-PREROLL_FRAMES:]
                return None
            self.active = True
            self.frames, self.preroll = self.preroll + [frame], []
            self.speech, self.silence = 1, 0
            return None
        self.frames.append(frame)
        if voiced:
            self.speech += 1
            self.silence = 0
        else:
            self.silence += 1
        if self.silence >= END_SILENCE_FRAMES or len(self.frames) >= MAX_SEGMENT_FRAMES:
            return self.flush()
        return None

    def flush(self):
        frames, speech = self.frames, self.speech
        self.frames, self.speech, self.silence, self.active = [], 0, 0, False
        return b"".join(frames) if speech >= MIN_SPEECH_FRAMES else None


def read_dotenv(path):
    values = {}
    try:
        for line in Path(path).read_text(encoding="utf-8").splitlines():
            line = line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            key, value = line.removeprefix("export ").split("=", 1)
            values[key.strip()] = value.strip().strip("'\"")
    except OSError:
        pass
    return values


def expand_refs(value, env):
    """${VAR} / ${env:VAR} seperti config Hermes; ref yang tidak ada jadi kosong."""
    return re.sub(r"\$\{(?:env:)?([A-Za-z_][A-Za-z0-9_]*)\}", lambda m: env.get(m.group(1), ""), value)


def load_llm_config():
    """Endpoint OpenAI-compatible: env > model di ~/.hermes/config.yaml (+ ~/.hermes/.env)."""
    config = {"base_url": "", "api_key": "", "model": ""}
    path = Path.home() / ".hermes/config.yaml"
    env = {**read_dotenv(Path.home() / ".hermes/.env"), **os.environ}
    try:
        import yaml
        model = (yaml.safe_load(path.read_text(encoding="utf-8")) or {}).get("model") or {}
        if isinstance(model, dict):
            config.update({key: expand_refs(str(model.get(field) or ""), env) for key, field in
                           (("base_url", "base_url"), ("api_key", "api_key"), ("model", "default"))})
    except ImportError:
        diagnostic("PyYAML tidak ada; pakai env HERMES_COUCOU_INTERVIEW_* untuk LLM")
    except (OSError, ValueError) as exc:
        diagnostic("Config Hermes tidak terbaca", exc)
    for key in ("base_url", "api_key"):
        value = os.environ.get("HERMES_COUCOU_INTERVIEW_" + key.upper())
        if value:
            config[key] = value
    config["base_url"] = config["base_url"].rstrip("/")
    # HERMES_COUCOU_INTERVIEW_MODEL boleh berisi beberapa model "a,b": dicoba berurutan.
    override = [m.strip() for m in os.environ.get("HERMES_COUCOU_INTERVIEW_MODEL", "").split(",") if m.strip()]
    if override:
        config["models"] = override
    else:
        fast = [FAST_MODEL_9ROUTER] if ":20128" in config["base_url"] else []
        config["models"] = [m for m in fast + [config["model"]] if m]
    return config


def stream_answer(config, messages):
    """Coba tiap model; pindah ke berikutnya hanya bila gagal sebelum teks pertama."""
    error = ValueError("Endpoint/model LLM belum diatur")
    for model in config.get("models") or []:
        produced = False
        try:
            for piece in stream_chat(dict(config, model=model), messages):
                produced = True
                yield piece
        except (OSError, ValueError) as exc:   # URLError/HTTPError turunan OSError
            if produced:
                raise
            diagnostic("Model " + model + " gagal, coba cadangan", exc)
            error = exc
            continue
        if produced:
            return
        diagnostic("Model " + model + " membalas kosong, coba cadangan")
    raise error


def stream_chat(config, messages, timeout=60):
    """Generator potongan teks dari /chat/completions (SSE)."""
    if not config.get("base_url") or not config.get("model"):
        raise ValueError("Endpoint/model LLM belum diatur")
    # Tanpa max_tokens: model reasoning bisa menghabiskan batas itu untuk berpikir
    # dan membalas konten kosong. Panjang jawaban dijaga lewat prompt.
    body = json.dumps({"model": config["model"], "messages": messages, "stream": True,
                       "temperature": 0.4}).encode("utf-8")
    headers = {"Content-Type": "application/json", "Accept": "text/event-stream"}
    if config.get("api_key"):
        headers["Authorization"] = "Bearer " + config["api_key"]
    request = urllib.request.Request(config["base_url"] + "/chat/completions", data=body, headers=headers)
    with urllib.request.urlopen(request, timeout=timeout) as response:
        for raw in response:
            line = raw.decode("utf-8", "replace").strip()
            if not line.startswith("data:"):
                continue
            data = line[5:].strip()
            if data == "[DONE]":
                return
            try:
                choice = (json.loads(data).get("choices") or [{}])[0]
            except (ValueError, AttributeError):
                continue
            piece = (choice.get("delta") or {}).get("content") or (choice.get("message") or {}).get("content")
            if piece:
                yield piece


class WhisperTranscriber:
    def __init__(self, model=None, language=None):
        self.model_name = model or os.environ.get("HERMES_COUCOU_INTERVIEW_WHISPER", "small")
        lang = language if language is not None else os.environ.get("HERMES_COUCOU_INTERVIEW_LANG", "")
        self.language = lang or None   # None = deteksi otomatis
        self.model = None

    def load(self):
        if self.model is None:
            from faster_whisper import WhisperModel
            threads = max(2, min(8, (os.cpu_count() or 4) - 2))
            self.model = WhisperModel(self.model_name, device="cpu", compute_type="int8", cpu_threads=threads)

    def __call__(self, pcm):
        import numpy as np
        self.load()
        audio = np.frombuffer(pcm, dtype=np.int16).astype(np.float32) / 32768.0
        segments, _ = self.model.transcribe(audio, language=self.language, beam_size=1, vad_filter=True,
                                            condition_on_previous_text=False)
        return " ".join(s.text.strip() for s in segments if s.no_speech_prob < 0.6).strip()


class InterviewAssistant:
    def __init__(self, emit, transcriber=None, llm=None, capture=None, profile_path=PROFILE_PATH,
                 log_dir=LOG_DIR, answer_delay=ANSWER_DELAY):
        self.emit = emit
        self.transcriber = transcriber or WhisperTranscriber()
        self.llm = llm or (lambda messages: stream_answer(load_llm_config(), messages))
        self.capture = capture or self._parec
        self.profile_path = Path(profile_path)
        self.log_dir = Path(log_dir)
        self.answer_delay = answer_delay
        self.lock = threading.RLock()
        self.proc = None
        self.session = 0          # naik tiap start/stop; worker lama berhenti sendiri
        self.generation = 0       # naik tiap jawaban baru; stream lama dibatalkan
        self.source = "system"
        self.auto = True
        self.state = "idle"
        self.transcript = []      # [(seq, text)]
        self.answered_seq = 0
        self.seq = 0
        self.timer = None
        self.log_path = None
        self.segments = queue.Queue(maxsize=8)

    # ---------- status ----------

    def _status(self, state, message=""):
        self.state = state
        self.emit({"event": "InterviewStatus", "state": state, "source": self.source, "auto": self.auto,
                   "message": message, "profile": str(self.profile_path),
                   "log": str(self.log_path) if self.log_path else ""})

    def emit_status(self):
        with self.lock:
            self._status(self.state)

    @staticmethod
    def _parec(source):
        if shutil.which("parec") is None:
            raise ValueError("parec tidak ditemukan (pasang pipewire-pulse / libpulse)")
        return subprocess.Popen(["parec", "--device=" + SOURCES[source], "--format=s16le", "--rate=%d" % RATE,
                                 "--channels=1", "--latency-msec=60", "--client-name=hermes-coucou-interview"],
                                stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)

    # ---------- perintah dari island ----------

    def start(self, source=None, auto=None):
        source = source or "system"
        if source not in SOURCES:
            raise ValueError("Sumber audio harus system atau mic")
        with self.lock:
            if self.proc is not None:
                self._stop_locked()
            self.source = source
            if auto is not None:
                self.auto = bool(auto)
            self.session += 1
            session = self.session
            self.transcript, self.answered_seq, self.seq = [], 0, 0
            self.segments = queue.Queue(maxsize=8)
            self._ensure_profile()
            self._open_log()
            self.proc = self.capture(source)
            self._status("loading", "Memuat model Whisper…")
        threading.Thread(target=self._read_loop, args=(session, self.proc, self.segments), daemon=True).start()
        threading.Thread(target=self._transcribe_loop, args=(session, self.segments), daemon=True).start()
        return "Interview assist aktif (" + ("audio sistem" if source == "system" else "mikrofon") + ")"

    def stop(self):
        with self.lock:
            if self.proc is None and self.state == "idle":
                return "Interview assist sudah mati"
            self._stop_locked()
            self._status("idle", "Berhenti" + (" — transkrip: " + str(self.log_path) if self.log_path else ""))
        return "Interview assist berhenti"

    def _stop_locked(self):
        self.session += 1
        self.generation += 1
        if self.timer is not None:
            self.timer.cancel()
            self.timer = None
        proc, self.proc = self.proc, None
        if proc is not None:
            proc.terminate()
            try:
                proc.wait(timeout=2)
            except subprocess.TimeoutExpired:
                proc.kill()
        try:
            self.segments.put_nowait(None)   # bangunkan worker transkripsi
        except queue.Full:
            pass

    def set_auto(self, enabled):
        with self.lock:
            self.auto = bool(enabled)
            self._status(self.state)
        return "Jawaban otomatis " + ("aktif" if self.auto else "mati")

    def answer_now(self):
        with self.lock:
            if not self.transcript:
                raise ValueError("Belum ada transkrip untuk dijawab")
            if self.answered_seq >= self.transcript[-1][0]:
                # Minta ulang jawaban untuk pertanyaan terakhir.
                self.answered_seq = self.transcript[-1][0] - 1
        self._answer(force=True)
        return "Membuat jawaban…"

    # ---------- pipeline ----------

    def _alive(self, session):
        return self.session == session

    def _read_loop(self, session, proc, segments):
        segmenter = Segmenter()
        last_level = 0.0
        last_level_at = 0.0
        try:
            while self._alive(session):
                frame = proc.stdout.read(FRAME_BYTES)
                if not frame or len(frame) < FRAME_BYTES:
                    break
                level = frame_level(frame)
                was_active = segmenter.active
                segment = segmenter.feed(frame, level)
                if segmenter.active and not was_active:
                    self._cancel_pending_answer(session)   # lawan bicara lanjut bicara
                now = time.monotonic()
                if now - last_level_at > 0.25 and abs(level - last_level) > 0.002:
                    last_level, last_level_at = level, now
                    self.emit({"event": "InterviewLevel", "level": round(min(1.0, level * 8), 3),
                               "speaking": segmenter.active})
                if segment is not None:
                    try:
                        segments.put_nowait(segment)
                    except queue.Full:
                        diagnostic("Transkripsi tertinggal; segmen dibuang")
        except (OSError, ValueError) as exc:
            diagnostic("Capture audio gagal", exc)
        with self.lock:
            if self._alive(session):
                self._stop_locked()
                self._status("error", "Rekaman audio berhenti tiba-tiba (cek PipeWire/perangkat)")

    def _transcribe_loop(self, session, segments):
        try:
            if hasattr(self.transcriber, "load"):
                self.transcriber.load()
        except Exception as exc:   # ImportError, model download, ctranslate2
            diagnostic("Whisper gagal dimuat", exc)
            with self.lock:
                if self._alive(session):
                    self._stop_locked()
                    self._status("error", "Whisper gagal dimuat: pastikan faster-whisper terpasang di python bridge")
            return
        with self.lock:
            if not self._alive(session):
                return
            self._status("listening", "Mendengarkan…")
        while True:
            segment = segments.get()
            if segment is None or not self._alive(session):
                return
            try:
                text = self.transcriber(segment)
            except Exception as exc:
                diagnostic("Transkripsi gagal", exc)
                continue
            if not text or not self._alive(session):
                continue
            with self.lock:
                self.seq += 1
                self.transcript.append((self.seq, text))
                self.transcript = self.transcript[-200:]
                self.emit({"event": "InterviewTranscript", "seq": self.seq, "text": text,
                           "time": time.strftime("%H:%M:%S")})
                self._log("**Pewawancara** (" + time.strftime("%H:%M:%S") + "): " + text)
                if self.auto:
                    self._schedule_answer()

    def _schedule_answer(self):
        if self.timer is not None:
            self.timer.cancel()
        self.timer = threading.Timer(self.answer_delay, self._answer)
        self.timer.daemon = True
        self.timer.start()

    def _cancel_pending_answer(self, session):
        with self.lock:
            if self._alive(session) and self.timer is not None:
                self.timer.cancel()
                self.timer = None

    def _answer(self, force=False):
        with self.lock:
            self.timer = None
            pending = [t for s, t in self.transcript if s > self.answered_seq]
            if not pending:
                return
            self.answered_seq = self.transcript[-1][0]
            self.generation += 1
            generation = self.generation
            question = " ".join(pending)
            context = [t for _, t in self.transcript[-MAX_CONTEXT_LINES:]]
        threading.Thread(target=self._generate, args=(generation, question, context, force), daemon=True).start()

    def _messages(self, question, context, force):
        profile = ""
        try:
            profile = self.profile_path.read_text(encoding="utf-8")[:PROFILE_LIMIT]
        except OSError:
            pass
        earlier = "\n".join("- " + line for line in context[:-1][-MAX_CONTEXT_LINES:]) or "(belum ada)"
        user = ("PROFIL KANDIDAT:\n" + (profile.strip() or "(kosong)") +
                "\n\nTRANSKRIP SEBELUMNYA (pewawancara):\n" + earlier +
                "\n\nUCAPAN TERAKHIR PEWAWANCARA:\n" + question)
        if force:
            user += "\n\n(Kandidat meminta jawaban secara manual: jangan balas SKIP.)"
        return [{"role": "system", "content": SYSTEM_PROMPT}, {"role": "user", "content": user}]

    def _generate(self, generation, question, context, force):
        qid = "a%d" % generation
        text, shown = "", False
        current = lambda: self.generation == generation
        try:
            for piece in self.llm(self._messages(question, context, force)):
                if not current():
                    return
                text += piece
                # Tahan beberapa karakter awal untuk mendeteksi "SKIP" tanpa berkedip di UI.
                if not shown and len(text.strip()) < 6 and "SKIP".startswith(text.strip().upper()):
                    continue
                shown = True
                self.emit({"event": "InterviewAnswer", "qid": qid, "question": question,
                           "text": text.strip(), "done": False})
        except (OSError, ValueError, urllib.error.URLError) as exc:
            diagnostic("LLM gagal", exc)
            if current():
                self.emit({"event": "InterviewAnswer", "qid": qid, "question": question, "text": "",
                           "done": True, "error": "LLM gagal: " + (str(exc)[:160] or type(exc).__name__)})
            return
        if not current():
            return
        if not text.strip():
            self.emit({"event": "InterviewAnswer", "qid": qid, "question": question, "text": "",
                       "done": True, "error": "LLM membalas kosong; coba Jawab lagi atau ganti model"})
            return
        if re.fullmatch(r"\W*SKIP\W*", text.strip(), re.IGNORECASE):
            self.emit({"event": "InterviewAnswer", "qid": qid, "question": question, "text": "",
                       "done": True, "skipped": True})
            return
        self.emit({"event": "InterviewAnswer", "qid": qid, "question": question, "text": text.strip(), "done": True})
        with self.lock:
            self._log("**Saran jawaban:**\n\n" + text.strip())

    # ---------- file ----------

    def _ensure_profile(self):
        if self.profile_path.exists():
            return
        try:
            self.profile_path.parent.mkdir(parents=True, exist_ok=True)
            fd = os.open(self.profile_path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
            with os.fdopen(fd, "w", encoding="utf-8") as stream:
                stream.write(PROFILE_TEMPLATE)
        except OSError as exc:
            diagnostic("Template profil gagal dibuat", exc)

    def _open_log(self):
        self.log_path = None
        try:
            self.log_dir.mkdir(parents=True, exist_ok=True, mode=0o700)
            path = self.log_dir / (time.strftime("%Y%m%d-%H%M%S") + ".md")
            fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
            with os.fdopen(fd, "w", encoding="utf-8") as stream:
                stream.write("# Interview " + time.strftime("%Y-%m-%d %H:%M") + "\n\n")
            self.log_path = path
        except OSError as exc:
            diagnostic("Log transkrip tidak bisa dibuat", exc)

    def _log(self, text):
        if self.log_path is None:
            return
        try:
            with open(self.log_path, "a", encoding="utf-8") as stream:
                stream.write(text + "\n\n")
        except OSError as exc:
            diagnostic("Gagal menulis log transkrip", exc)
