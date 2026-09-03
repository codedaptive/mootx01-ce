"""Tests for moot_hooks.py — plan capture (plan-approved, plan-filed,
precommit-check) and the state those modes keep across a compaction.

Run with:
    python3 -m unittest discover -s distribution/plugin/tests -p "test_*.py"

Each test uses a unique session id and its own temp cwd, so the hook's
temp-dir state file never leaks between tests. Printing is captured by
patching builtins.print; the daemon probe is patched reachable unless a test
says otherwise, so no test depends on a running mootx01.
"""
import hashlib
import json
import os
import subprocess
import sys
import tempfile
import unittest
import uuid
from unittest.mock import patch

_HOOKS_DIR = os.path.join(os.path.dirname(__file__), "..", "hooks")
sys.path.insert(0, os.path.abspath(_HOOKS_DIR))

import moot_hooks  # noqa: E402

PLAN_A = "# Refactor Auth Flow\n\n1. Extract the token store.\n2. Add tests.\n"
PLAN_B = "# Ship The Meter\n\n1. Wire the hook.\n"


class PlanCase(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.mkdtemp(prefix="moot-plan-")
        self.project = os.path.basename(self.dir)
        self.session_id = "test-%s" % uuid.uuid4().hex
        self.reachable = patch("moot_hooks.is_daemon_reachable", return_value=True)
        self.reachable.start()

    def tearDown(self):
        self.reachable.stop()
        try:
            os.remove(moot_hooks.state_path(self.session_id))
        except OSError:
            pass

    def run_mode(self, fn, data):
        printed = []
        with patch("builtins.print", side_effect=lambda *a, **k: printed.append(" ".join(str(x) for x in a))):
            fn(data)
        return printed

    def base(self, **extra):
        data = {"session_id": self.session_id, "cwd": self.dir}
        data.update(extra)
        return data

    def approve(self, plan):
        return self.run_mode(moot_hooks.mode_plan_approved,
                             self.base(tool_name="ExitPlanMode", tool_input={"plan": plan}))

    def file_to(self, location):
        return self.run_mode(moot_hooks.mode_plan_filed, self.base(
            tool_name="mcp__plugin_mootx01_memory__moot_file_memory",
            tool_input={"location": location, "content": "plan"}))

    def bash(self, command):
        return self.run_mode(moot_hooks.mode_precommit_check,
                             self.base(tool_name="Bash", tool_input={"command": command}))

    def injected(self, printed, event):
        """The one JSON document on stdout, checked for the injection shape the
        hooks reference gives for PreToolUse / PostToolUse, minus any decision
        field (the tool call must never be blocked)."""
        self.assertEqual(len(printed), 1, printed)
        doc = json.loads(printed[0])
        self.assertEqual(list(doc.keys()), ["hookSpecificOutput"], doc)
        out = doc["hookSpecificOutput"]
        self.assertEqual(out["hookEventName"], event)
        self.assertNotIn("permissionDecision", out)
        self.assertNotIn("decision", doc)
        return out["additionalContext"]

    def state(self):
        return moot_hooks.load_state(self.session_id)

    @staticmethod
    def digest(plan):
        return hashlib.sha256(plan.encode("utf-8")).hexdigest()[:12]


class TestApproval(PlanCase):

    def test_approval_injects_once_with_location_and_sets_hash(self):
        text = self.injected(self.approve(PLAN_A), "PostToolUse")
        location = "plans/%s/refactor-auth-flow" % self.project
        self.assertIn("`%s`" % location, text)
        self.assertIn("moot_file_memory", text)
        self.assertIn("verbatim", text)
        self.assertNotIn("already approved", text)
        self.assertNotIn("unreachable", text)
        self.assertEqual(self.state().get("plan_pending"), self.digest(PLAN_A))
        self.assertEqual(self.state().get("plan_location"), location)

    def test_reapproval_of_identical_text_keeps_the_hash_and_says_update(self):
        self.approve(PLAN_A)
        text = self.injected(self.approve(PLAN_A), "PostToolUse")
        self.assertIn("already approved", text)
        self.assertIn("update the existing note", text)
        self.assertIn(self.digest(PLAN_A), text)
        self.assertEqual(self.state().get("plan_pending"), self.digest(PLAN_A))

    def test_a_different_plan_replaces_the_hash(self):
        self.approve(PLAN_A)
        text = self.injected(self.approve(PLAN_B), "PostToolUse")
        self.assertNotIn("already approved", text)
        self.assertIn("plans/%s/ship-the-meter" % self.project, text)
        self.assertEqual(self.state().get("plan_pending"), self.digest(PLAN_B))

    def test_reapproval_after_filing_still_says_update(self):
        self.approve(PLAN_A)
        self.file_to("plans/%s/refactor-auth-flow" % self.project)
        text = self.injected(self.approve(PLAN_A), "PostToolUse")
        self.assertIn("update the existing note", text)
        self.assertEqual(self.state().get("plan_pending"), self.digest(PLAN_A))

    def test_plan_is_read_from_tool_response_before_tool_input(self):
        printed = self.run_mode(moot_hooks.mode_plan_approved, self.base(
            tool_input={}, tool_response={"plan": "# From Response\n", "filePath": "/x"}))
        text = self.injected(printed, "PostToolUse")
        self.assertIn("plans/%s/from-response" % self.project, text)

    def test_unreachable_estate_appends_the_paste_sentence(self):
        self.reachable.stop()
        with patch("moot_hooks.is_daemon_reachable", return_value=False):
            text = self.injected(self.approve(PLAN_A), "PostToolUse")
        self.reachable.start()
        self.assertIn("unreachable", text)
        self.assertIn("paste the plan somewhere durable", text)
        self.assertEqual(self.state().get("plan_pending"), self.digest(PLAN_A))

    def test_slug_comes_from_the_first_heading(self):
        self.assertEqual(moot_hooks.plan_slug("## Hello, World!! (v2)\n"), "hello-world-v2")
        self.assertEqual(moot_hooks.plan_slug("intro line\n### Second: Part ###\n"), "second-part")
        self.assertEqual(moot_hooks.plan_slug("no heading at all\n"), "untitled-plan")
        self.assertEqual(moot_hooks.plan_slug("# ---\n"), "untitled-plan")
        self.assertEqual(moot_hooks.plan_hash(PLAN_A), self.digest(PLAN_A))

    def test_project_is_the_git_top_level_basename(self):
        subprocess.run(["git", "init", "-q", self.dir], check=True)
        sub = os.path.join(self.dir, "deep", "er")
        os.makedirs(sub)
        self.assertEqual(moot_hooks.project_name(sub), self.project)
        plain = tempfile.mkdtemp(prefix="moot-plain-")
        self.assertEqual(moot_hooks.project_name(plain), os.path.basename(plain))
        self.assertEqual(moot_hooks.project_name(""), "unknown-project")

    def test_empty_or_malformed_input_is_silent(self):
        for data in ({}, {"tool_input": None}, {"tool_input": {"plan": ""}},
                     {"tool_input": {"plan": 7}}, {"tool_response": "text"}):
            self.assertEqual(self.run_mode(moot_hooks.mode_plan_approved, data), [], data)
        self.assertNotIn("plan_pending", self.state())


class TestFiled(PlanCase):

    def test_filing_to_plans_clears_the_flag_silently(self):
        self.approve(PLAN_A)
        self.assertEqual(self.file_to("plans/%s/refactor-auth-flow" % self.project), [])
        self.assertNotIn("plan_pending", self.state())
        self.assertEqual(self.state().get("plan_filed"), self.digest(PLAN_A))

    def test_filing_elsewhere_does_not_clear_the_flag(self):
        self.approve(PLAN_A)
        self.assertEqual(self.file_to("session/%s/handoff" % self.session_id), [])
        self.assertEqual(self.file_to("planning/notes"), [])
        self.assertEqual(self.state().get("plan_pending"), self.digest(PLAN_A))

    def test_nothing_else_clears_the_flag(self):
        self.approve(PLAN_A)
        with patch("moot_hooks.warn_competing_direct_entry"):
            self.run_mode(moot_hooks.mode_session, self.base(source="compact"))
            self.run_mode(moot_hooks.mode_session, self.base(source="clear"))
        self.run_mode(moot_hooks.mode_precompact, self.base(transcript_path=None))
        self.assertEqual(self.state().get("plan_pending"), self.digest(PLAN_A))

    def test_empty_or_malformed_input_is_silent(self):
        for data in ({}, {"tool_input": None}, {"tool_input": {"location": 3}},
                     {"tool_input": {}}):
            self.assertEqual(self.run_mode(moot_hooks.mode_plan_filed, data), [], data)


class TestPrecommit(PlanCase):

    def test_commit_with_flag_set_injects_once_and_never_blocks(self):
        self.approve(PLAN_A)
        text = self.injected(self.bash("git commit -m 'x'"), "PreToolUse")
        self.assertIn("plans/%s/refactor-auth-flow" % self.project, text)
        self.assertIn("not in moot yet", text)
        self.assertIn("continue with the commit", text)
        self.assertTrue(self.state().get("plan_reminded"))
        self.assertEqual(self.bash("git commit -m 'y'"), [], "second commit must be silent")
        self.assertEqual(self.state().get("plan_pending"), self.digest(PLAN_A),
                         "the reminder does not clear the flag")

    def test_commit_after_separators_and_git_options_is_recognised(self):
        for command in ("cd /tmp && git commit -am x",
                        "swift test; git commit -m done",
                        "git -C /some/path commit -m x",
                        "git -c user.name=Bilby -c user.email=b@c commit -m x",
                        "git -c commit.gpgsign=false commit -m x",
                        "GIT_AUTHOR_NAME=B git commit --amend --no-edit"):
            self.approve(PLAN_A)
            moot_hooks.save_state(self.session_id, dict(self.state(), plan_reminded=False))
            self.assertEqual(len(self.bash(command)), 1, command)

    def test_commit_with_flag_clear_injects_nothing(self):
        self.assertEqual(self.bash("git commit -m 'x'"), [])
        self.assertNotIn("plan_reminded", self.state())
        self.approve(PLAN_A)
        self.file_to("plans/%s/refactor-auth-flow" % self.project)
        self.assertEqual(self.bash("git commit -m 'x'"), [])

    def test_non_commit_bash_injects_nothing(self):
        self.approve(PLAN_A)
        for command in ("git status", "ls -la", "git log --oneline -3",
                        "echo commit", "git add -A", "git revert --no-commit HEAD",
                        "git commit-graph write"):
            self.assertEqual(self.bash(command), [], command)
        self.assertNotIn("plan_reminded", self.state())

    def test_reminder_survives_a_compaction(self):
        self.approve(PLAN_A)
        with patch("moot_hooks.warn_competing_direct_entry"):
            self.run_mode(moot_hooks.mode_session, self.base(source="compact"))
        self.assertEqual(len(self.bash("git commit -m x")), 1)

    def test_empty_or_malformed_input_is_silent(self):
        self.approve(PLAN_A)
        for data in ({}, {"tool_input": None}, {"tool_input": {"command": 5}},
                     {"tool_input": {}}):
            self.assertEqual(self.run_mode(moot_hooks.mode_precommit_check, data), [], data)


class TestMainIsSilentOnBadStdin(unittest.TestCase):

    def test_each_mode_exits_zero_silently_on_empty_or_malformed_stdin(self):
        script = os.path.abspath(moot_hooks.__file__)
        for mode in ("plan-approved", "plan-filed", "precommit-check"):
            for stdin in ("", "not json", "[]", '{"tool_input": "x"}'):
                result = subprocess.run([sys.executable, script, mode], input=stdin,
                                        capture_output=True, text=True, timeout=20)
                self.assertEqual(result.returncode, 0, (mode, stdin, result.stderr))
                self.assertEqual(result.stdout, "", (mode, stdin))


if __name__ == "__main__":
    unittest.main()
