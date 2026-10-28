import sys
import threading
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import voice


class FakeApps:
    APPS = {"chromium": {"id": "chromium", "name": "Chromium"},
            "code": {"id": "code", "name": "Visual Studio Code"},
            "kitty": {"id": "kitty", "name": "kitty"}}

    def find(self, query):
        return self.APPS.get(voice.normalize(query))


class FakeLauncher:
    def __init__(self):
        self.calls = []

    def spawn(self, argv):
        self.calls.append(("spawn", argv))

    def launch(self, command):
        self.calls.append(("launch", command))

    def media(self, name):
        self.calls.append(("media", name))


class Quiet:
    backend = "none"

    def say(self, text):
        pass


def assistant(llm=None):
    events = []
    launcher = FakeLauncher()
    va = voice.VoiceAssistant(events.append, launcher, transcriber=object(), speaker=Quiet(),
                              apps=FakeApps(), llm=llm or (lambda m: iter(["{}"])))
    return va, events, launcher


def run(va, text):
    va._handle_command(text)


class WakeTest(unittest.TestCase):
    def test_variants_are_detected(self):
        for text in ("Halo QBot.", "hallo kyu bot", "Hai, cu-bot!", "hello q bot buka youtube"):
            self.assertTrue(voice.split_wake(text)[0], text)

    def test_command_after_name_is_returned(self):
        self.assertEqual(voice.split_wake("Halo QBot, buka Chromium dan buka YouTube.")[1],
                         "buka chromium dan buka youtube")

    def test_other_speech_ignored(self):
        for text in ("robot itu lucu", "halo semuanya", "kubota traktor"):
            self.assertFalse(voice.split_wake(text)[0], text)


class ParserTest(unittest.TestCase):
    def setUp(self):
        self.parser = voice.CommandParser(FakeApps())

    def test_open_app_and_site(self):
        self.assertEqual(self.parser.parse("buka chromium dan buka youtube"),
                         [{"type": "open_app", "app": "chromium"},
                          {"type": "open_url", "url": "https://www.youtube.com", "browser": None}])

    def test_site_in_specific_browser(self):
        self.assertEqual(self.parser.parse("buka github di chromium"),
                         [{"type": "open_url", "url": "https://github.com", "browser": "chromium"}])

    def test_search_youtube(self):
        self.assertEqual(self.parser.parse("cari lagu lofi di youtube"),
                         [{"type": "search", "engine": "youtube", "query": "lagu lofi"}])

    def test_media_and_volume(self):
        self.assertEqual(self.parser.parse("naikkan volume lalu lagu berikutnya"),
                         [{"type": "volume", "name": "up"}, {"type": "media", "name": "next"}])

    def test_unknown_goes_to_llm(self):
        self.assertIsNone(self.parser.parse("apa kabar hari ini"))
        self.assertIsNone(self.parser.parse("buka aplikasi yang tidak ada"))


class AssistantTest(unittest.TestCase):
    def test_browser_then_site_opens_one_window(self):
        va, events, launcher = assistant()
        run(va, "buka chromium dan buka youtube")
        self.assertEqual(launcher.calls, [("spawn", ["chromium", "https://www.youtube.com"])])
        reply = [e for e in events if e["event"] == "VoiceReply"][-1]
        self.assertTrue(reply["ok"])
        self.assertEqual(reply["text"], "Siap, membuka YouTube di Chromium.")

    def test_llm_actions_are_validated(self):
        llm = lambda m: iter(['Oke! {"reply": "Siap", "actions": [',
                              '{"type": "shell", "cmd": "rm -rf ~"},',
                              '{"type": "open_url", "url": "file:///etc/passwd"},',
                              '{"type": "open_app", "app": "kitty"}]}'])
        va, events, launcher = assistant(llm)
        run(va, "lakukan sesuatu yang aneh")
        self.assertEqual(launcher.calls, [("spawn", ["gtk-launch", "kitty"])])
        reply = [e for e in events if e["event"] == "VoiceReply"][-1]
        self.assertFalse(reply["ok"])
        self.assertIn("gagal", reply["text"])

    def test_chat_reply_without_actions(self):
        va, events, launcher = assistant(lambda m: iter(['{"reply": "Baik, terima kasih!", "actions": []}']))
        run(va, "apa kabar")
        self.assertEqual(launcher.calls, [])
        self.assertEqual([e for e in events if e["event"] == "VoiceReply"][-1]["text"], "Baik, terima kasih!")

    def test_llm_failure_is_reported(self):
        def broken(messages):
            raise ValueError("Endpoint/model LLM belum diatur")
        va, events, launcher = assistant(broken)
        run(va, "apa kabar")
        reply = [e for e in events if e["event"] == "VoiceReply"][-1]
        self.assertFalse(reply["ok"])
        self.assertEqual(va.state, "off")

    def test_run_text_requires_text(self):
        va, _, _ = assistant()
        with self.assertRaises(ValueError):
            va.run_text("   ")


if __name__ == "__main__":
    unittest.main()
