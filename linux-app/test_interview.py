import io
import struct
import sys
import tempfile
import threading
import time
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import interview as iv


def tone(frames, amplitude):
    sample = struct.pack("<h", amplitude)
    return [sample * iv.FRAME for _ in range(frames)]


class FakeStream:
    """Seperti pipe parec: setelah data habis, read() menunggu sampai proses dihentikan."""
    def __init__(self, data, hold):
        self.data = io.BytesIO(data)
        self.hold = hold
        self.closed = threading.Event()

    def read(self, size):
        chunk = self.data.read(size)
        if not chunk and self.hold:
            self.closed.wait(5)
        return chunk


class FakeProc:
    def __init__(self, data, hold=True):
        self.stdout = FakeStream(data, hold)

    def terminate(self):
        self.stdout.closed.set()

    def wait(self, timeout=None):
        return 0

    def kill(self):
        pass


class SegmenterTest(unittest.TestCase):
    def run_frames(self, frames):
        seg = iv.Segmenter()
        out = []
        for frame in frames:
            result = seg.feed(frame, iv.frame_level(frame))
            if result is not None:
                out.append(result)
        return out

    def test_speech_then_silence_yields_one_segment_with_preroll(self):
        frames = tone(30, 0) + tone(40, 6000) + tone(40, 0)
        segments = self.run_frames(frames)
        self.assertEqual(len(segments), 1)
        total = len(segments[0]) // iv.FRAME_BYTES
        self.assertEqual(total, iv.PREROLL_FRAMES + 40 + iv.END_SILENCE_FRAMES)

    def test_short_click_is_dropped(self):
        self.assertEqual(self.run_frames(tone(20, 0) + tone(3, 8000) + tone(40, 0)), [])

    def test_long_speech_is_cut(self):
        segments = self.run_frames(tone(iv.MAX_SEGMENT_FRAMES * 2 + 5, 6000))
        self.assertEqual(len(segments), 2)


class AssistantTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.events = []
        self.lock = threading.Lock()
        self.prompts = []
        self.reply = ["Saya ", "punya 3 tahun ", "pengalaman Laravel."]

    def tearDown(self):
        self.tmp.cleanup()

    def emit(self, event):
        with self.lock:
            self.events.append(event)

    def llm(self, messages):
        self.prompts.append(messages)
        yield from self.reply

    def assistant(self, audio, hold=True):
        root = Path(self.tmp.name)
        return iv.InterviewAssistant(self.emit, transcriber=lambda pcm: "Ceritakan pengalaman Anda?",
                                     llm=self.llm, capture=lambda source: FakeProc(audio, hold),
                                     profile_path=root / "profile.md", log_dir=root / "logs", answer_delay=0.05)

    def wait_for(self, predicate, timeout=3):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            with self.lock:
                if predicate(list(self.events)):
                    return
            time.sleep(0.02)
        self.fail("event tidak muncul: " + repr(self.events[-5:]))

    def answers(self, events):
        return [e for e in events if e["event"] == "InterviewAnswer" and e.get("done")]

    def test_transcript_then_auto_answer_and_log(self):
        audio = b"".join(tone(20, 0) + tone(40, 6000) + tone(40, 0))
        assistant = self.assistant(audio)
        assistant.start("system", True)
        self.wait_for(lambda ev: self.answers(ev))
        answer = self.answers(self.events)[-1]
        self.assertEqual(answer["text"], "Saya punya 3 tahun pengalaman Laravel.")
        self.assertEqual(answer["question"], "Ceritakan pengalaman Anda?")
        self.assertIn("PROFIL KANDIDAT", self.prompts[0][1]["content"])
        self.assertTrue((Path(self.tmp.name) / "profile.md").is_file())
        log = next((Path(self.tmp.name) / "logs").glob("*.md")).read_text()
        self.assertIn("Ceritakan pengalaman", log)
        self.assertIn("Laravel", log)
        assistant.stop()

    def test_skip_is_not_shown(self):
        self.reply = ["SK", "IP"]
        assistant = self.assistant(b"".join(tone(20, 0) + tone(40, 6000) + tone(40, 0)))
        assistant.start("system", True)
        self.wait_for(lambda ev: self.answers(ev))
        streamed = [e for e in self.events if e["event"] == "InterviewAnswer" and not e.get("done")]
        self.assertEqual(streamed, [])
        self.assertTrue(self.answers(self.events)[-1].get("skipped"))
        assistant.stop()

    def test_manual_answer_without_auto(self):
        assistant = self.assistant(b"".join(tone(20, 0) + tone(40, 6000) + tone(40, 0)))
        assistant.start("mic", False)
        self.wait_for(lambda ev: any(e["event"] == "InterviewTranscript" for e in ev))
        time.sleep(0.15)
        self.assertEqual(self.answers(self.events), [])
        assistant.answer_now()
        self.wait_for(lambda ev: self.answers(ev))
        self.assertIn("jangan balas SKIP", self.prompts[-1][1]["content"])
        assistant.stop()

    def test_capture_ending_reports_error(self):
        assistant = self.assistant(b"", hold=False)
        assistant.start("system", True)
        self.wait_for(lambda ev: any(e["event"] == "InterviewStatus" and e["state"] == "error" for e in ev))

    def test_invalid_source_rejected(self):
        with self.assertRaises(ValueError):
            self.assistant(b"").start("hdmi")

    def test_llm_error_reported(self):
        def broken(messages):
            raise OSError("connection refused")
            yield
        assistant = self.assistant(b"".join(tone(20, 0) + tone(40, 6000) + tone(40, 0)))
        assistant.llm = broken
        assistant.start("system", True)
        self.wait_for(lambda ev: self.answers(ev))
        self.assertIn("LLM gagal", self.answers(self.events)[-1]["error"])
        assistant.stop()


class FallbackTest(unittest.TestCase):
    def test_next_model_used_when_first_fails_before_text(self):
        calls = []
        def fake_chat(config, messages):
            calls.append(config["model"])
            if config["model"] == "fast":
                raise OSError("503")
            yield "ok"
        original = iv.stream_chat
        iv.stream_chat = fake_chat
        try:
            out = "".join(iv.stream_answer({"models": ["fast", "combo"]}, []))
        finally:
            iv.stream_chat = original
        self.assertEqual(out, "ok")
        self.assertEqual(calls, ["fast", "combo"])

    def test_empty_reply_falls_back_and_all_failing_raises(self):
        def fake_chat(config, messages):
            if config["model"] == "empty":
                return
            raise OSError("down")
            yield
        original = iv.stream_chat
        iv.stream_chat = fake_chat
        try:
            with self.assertRaises(OSError):
                "".join(iv.stream_answer({"models": ["empty", "down"]}, []))
        finally:
            iv.stream_chat = original


if __name__ == "__main__":
    unittest.main()
