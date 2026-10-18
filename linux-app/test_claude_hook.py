import io
import json
import unittest
from unittest.mock import patch

import claude_hook


class InteractiveHookTests(unittest.TestCase):
    PERM = {"hook_event_name": "PermissionRequest", "tool_name": "Bash", "cwd": "/x/best-cso",
            "tool_input": {"command": "git push", "description": "Push"},
            "permission_suggestions": [{"type": "addRules", "behavior": "allow"}]}
    ASK = {"hook_event_name": "PreToolUse", "tool_name": "AskUserQuestion",
           "tool_input": {"questions": [
               {"question": "Framework?", "header": "FW", "options": [{"label": "React"}, {"label": "Vue"}]},
               {"question": "Fitur?", "header": "F", "multiSelect": True, "options": [{"label": "A"}, {"label": "B"}]}]}}

    def run_with(self, hook, answer):
        with patch.object(claude_hook, "ask_island", return_value=answer) as ask:
            return claude_hook.interactive(hook), ask

    def test_permission_allow_deny_always(self):
        out, ask = self.run_with(self.PERM, {"decision": "allow"})
        self.assertEqual(out["hookSpecificOutput"]["decision"], {"behavior": "allow"})
        self.assertEqual(ask.call_args.args[1:3], ("permission", "Izinkan Bash?"))
        self.assertIn("git push", ask.call_args.args[3])
        out, _ = self.run_with(self.PERM, {"decision": "always"})
        self.assertEqual(out["hookSpecificOutput"]["decision"]["updatedPermissions"], self.PERM["permission_suggestions"])
        out, _ = self.run_with(self.PERM, {"decision": "deny"})
        self.assertEqual(out["hookSpecificOutput"]["decision"]["behavior"], "deny")

    def test_full_command_sent_only_for_bash(self):
        long_cmd = "ls " + "a" * 3000
        _, ask = self.run_with({**self.PERM, "tool_input": {"command": long_cmd, "description": "List"}}, None)
        self.assertEqual(ask.call_args.kwargs["command"], long_cmd)
        _, ask = self.run_with({**self.PERM, "tool_name": "Write", "tool_input": {"command": "ls", "file_path": "/x"}}, None)
        self.assertEqual(ask.call_args.kwargs["command"], "")

    def test_question_answers_fill_updated_input(self):
        out, _ = self.run_with(self.ASK, {"answers": [["Vue"], ["A", "B"]]})
        spec = out["hookSpecificOutput"]
        self.assertEqual(spec["permissionDecision"], "allow")
        self.assertEqual(spec["updatedInput"]["answers"], {"Framework?": "Vue", "Fitur?": "A, B"})
        self.assertEqual(spec["updatedInput"]["questions"], self.ASK["tool_input"]["questions"])

    def test_no_answer_falls_back_to_terminal(self):
        for hook in (self.PERM, self.ASK):
            self.assertIsNone(self.run_with(hook, None)[0])
        # AskUserQuestion's own permission prompt is left to PreToolUse / terminal.
        out, ask = self.run_with({**self.PERM, "tool_name": "AskUserQuestion"}, {"decision": "allow"})
        self.assertIsNone(out)
        ask.assert_not_called()

    def test_bridge_down_means_silence(self):
        stdin, stdout = io.StringIO(json.dumps(self.PERM)), io.StringIO()
        with patch.dict("os.environ", {"HERMES_COUCOU_PORT": "1"}), patch("sys.stdin", stdin), \
                patch("sys.stdout", stdout), patch("sys.argv", ["claude_hook.py", "--interactive"]):
            self.assertEqual(claude_hook.main(), 0)
        self.assertEqual(stdout.getvalue(), "")


if __name__ == "__main__":
    unittest.main()
