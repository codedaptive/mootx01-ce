"""Tests for moot_hooks.py — the context meter (mode_context), precompact
handoff check, and post-compact recovery text.

Run with:
    python3 -m unittest discover -s distribution/plugin/tests -p "test_*.py"

Each test writes its own JSONL transcript and uses a unique session id, so
the hook's temp-dir state file never leaks between tests. Printing is
captured by patching builtins.print; MOOTX01_CONTEXT_WINDOW is cleared so
the window comes from the model id alone.
"""
import json
import os
import sys
import tempfile
import unittest
import uuid
from unittest.mock import patch

_HOOKS_DIR = os.path.join(os.path.dirname(__file__), "..", "hooks")
sys.path.insert(0, os.path.abspath(_HOOKS_DIR))

import moot_hooks  # noqa: E402


def _usage_entry(model, total, sidechain=False):
    """One assistant transcript line whose usage sums to `total` tokens."""
    return json.dumps({
        "isSidechain": sidechain,
        "message": {
            "model": model,
            "usage": {
                "input_tokens": total - 1,
                "cache_read_input_tokens": 0,
                "cache_creation_input_tokens": 0,
                "output_tokens": 1,
            },
        },
    })


class MeterCase(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.mkdtemp(prefix="moot-meter-")
        self.session_id = "test-%s" % uuid.uuid4().hex
        self.env = patch.dict(os.environ)
        self.env.start()
        os.environ.pop("MOOTX01_CONTEXT_WINDOW", None)

    def tearDown(self):
        self.env.stop()
        try:
            os.remove(moot_hooks.state_path(self.session_id))
        except OSError:
            pass

    def transcript(self, *lines):
        path = os.path.join(self.dir, "transcript.jsonl")
        with open(path, "w", encoding="utf-8") as fh:
            fh.write("\n".join(lines) + "\n")
        return path

    def run_context(self, path):
        printed = []
        with patch("builtins.print", side_effect=lambda *a, **k: printed.append(" ".join(str(x) for x in a))):
            moot_hooks.mode_context({"session_id": self.session_id, "transcript_path": path})
        return printed


class TestWindowByModel(MeterCase):

    def test_fable_reads_against_one_million(self):
        # 500,820 tokens on claude-fable-5 is 50% — the figure /context shows.
        path = self.transcript(_usage_entry("claude-fable-5", 500_820))
        printed = self.run_context(path)
        self.assertEqual(len(printed), 1, printed)
        self.assertIn("about 50% full", printed[0])
        self.assertIn("checkpoint-50", printed[0])

    def test_fable_below_two_hundred_k_is_not_inflated(self):
        # 140k on a 1M model is 14%: no rung crossed, nothing printed. A 200k
        # assumption reads 70% and fires a rung on a nearly empty session.
        path = self.transcript(_usage_entry("claude-fable-5-1", 140_000))
        self.assertEqual(self.run_context(path), [])

    def test_sonnet_four_six_still_divides_by_two_hundred_k(self):
        path = self.transcript(_usage_entry("claude-sonnet-4-6", 100_000))
        printed = self.run_context(path)
        self.assertEqual(len(printed), 1, printed)
        self.assertIn("about 50% full", printed[0])

    def test_one_m_suffix_wins_over_standard_fragment(self):
        self.assertEqual(moot_hooks.window_for_model("claude-sonnet-4-6[1m]"), 1_000_000)
        self.assertEqual(moot_hooks.window_for_model("claude-opus-5"), 1_000_000)
        self.assertEqual(moot_hooks.window_for_model("claude-haiku-4-5-20251001"), 200_000)

    def test_environment_override_beats_the_model(self):
        os.environ["MOOTX01_CONTEXT_WINDOW"] = "400000"
        path = self.transcript(_usage_entry("claude-fable-5", 200_000))
        printed = self.run_context(path)
        self.assertEqual(len(printed), 1, printed)
        self.assertIn("about 50% full", printed[0])

    def test_sidechain_entries_are_ignored(self):
        path = self.transcript(
            _usage_entry("claude-fable-5", 100_000),
            _usage_entry("claude-fable-5", 900_000, sidechain=True),
        )
        self.assertEqual(self.run_context(path), [])


class TestUnknownModel(MeterCase):

    def assert_unknown(self, printed):
        self.assertEqual(len(printed), 1, printed)
        self.assertIn("UNKNOWN", printed[0])
        self.assertIn("/context", printed[0])
        self.assertNotIn("% full", printed[0])

    def test_synthetic_last_entry_reports_unknown(self):
        path = self.transcript(
            _usage_entry("claude-fable-5", 300_000),
            _usage_entry("<synthetic>", 300_500),
        )
        self.assert_unknown(self.run_context(path))

    def test_unlisted_model_reports_unknown_not_a_percentage(self):
        # claude-opus-4-8's window is not established from a primary source.
        path = self.transcript(_usage_entry("claude-opus-4-8", 190_000))
        self.assert_unknown(self.run_context(path))

    def test_missing_model_reports_unknown(self):
        line = json.dumps({"message": {"usage": {"input_tokens": 199_000, "output_tokens": 1}}})
        self.assert_unknown(self.run_context(self.transcript(line)))

    def test_unknown_is_reported_once_per_session(self):
        path = self.transcript(_usage_entry("<synthetic>", 300_000))
        self.assertEqual(len(self.run_context(path)), 1)
        self.assertEqual(self.run_context(path), [])
        self.assertIsNone(moot_hooks.window_for_model("<synthetic>"))
        self.assertIsNone(moot_hooks.window_for_model(""))
        self.assertIsNone(moot_hooks.window_for_model(None))


class TestRungsFireOnce(MeterCase):

    def test_each_rung_fires_once_and_only_the_highest_crossed(self):
        self.assertEqual(moot_hooks.THRESHOLDS, (30, 50, 70, 85))
        # 32%: rung 30 once.
        path = self.transcript(_usage_entry("claude-fable-5", 320_000))
        first = self.run_context(path)
        self.assertEqual(len(first), 1)
        self.assertIn("checkpoint-30", first[0])
        self.assertIn(self.session_id, first[0])
        self.assertEqual(self.run_context(path), [], "a rung must not repeat on the next prompt")
        # 72%: rungs 50 and 70 are both new; only 70 is announced.
        path = self.transcript(_usage_entry("claude-fable-5", 720_000))
        third = self.run_context(path)
        self.assertEqual(len(third), 1)
        self.assertIn("checkpoint-70", third[0])
        self.assertEqual(self.run_context(path), [])
        # 86%: the handoff rung, once.
        path = self.transcript(_usage_entry("claude-fable-5", 860_000))
        fourth = self.run_context(path)
        self.assertEqual(len(fourth), 1)
        self.assertIn("session/%s/handoff" % self.session_id, fourth[0])
        self.assertIn("Then compact", fourth[0])
        self.assertEqual(self.run_context(path), [])

    def test_every_rung_message_names_a_session_scoped_location(self):
        for rung, template in moot_hooks.MESSAGES.items():
            text = template.format(pct=rung, session_id="S")
            expected = "session/S/handoff" if rung == 85 else "session/S/checkpoint-%d" % rung
            self.assertIn(expected, text)

    def test_every_rung_message_carries_sensitivity_reminder(self):
        """a46c8160 — every checkpoint rung must warn the model not to include
        credentials or restricted content in the filed note.

        Fails pre-fix because the MESSAGES templates contain no sensitivity
        guidance, so a handoff can silently downgrade secret context to normal.
        """
        # SECURITY: the reminder prevents the model from inadvertently filing
        # credentials or restricted-memory content into an estate note at the
        # default (normal) sensitivity tier.
        required_phrases = (
            "credentials, keys or tokens",
            "restricted or secret memories",
            "sensitivity set to the highest tier",
        )
        for rung, template in moot_hooks.MESSAGES.items():
            text = template.format(pct=rung, session_id="S")
            for phrase in required_phrases:
                self.assertIn(
                    phrase, text,
                    "Rung %d MESSAGES template is missing sensitivity phrase %r" % (rung, phrase),
                )


class TestPrecompactAndRecovery(MeterCase):

    def run_mode(self, fn, data):
        printed = []
        with patch("builtins.print", side_effect=lambda *a, **k: printed.append(" ".join(str(x) for x in a))):
            fn(data)
        return printed

    def test_precompact_reports_a_missing_handoff(self):
        path = self.transcript(_usage_entry("claude-fable-5", 900_000))
        printed = self.run_mode(moot_hooks.mode_precompact,
                                {"session_id": self.session_id, "transcript_path": path})
        self.assertEqual(len(printed), 1, printed)
        self.assertIn("no post-compact handoff was filed", printed[0])
        self.assertIn("session/%s/handoff" % self.session_id, printed[0])

    def test_precompact_is_silent_when_the_handoff_was_filed(self):
        tool_line = json.dumps({"message": {"content": [{
            "type": "tool_use", "name": "mcp__plugin_mootx01_memory__moot_file_memory",
            "input": {"location": "session/%s/handoff" % self.session_id, "content": "handoff"}}]}})
        path = self.transcript(_usage_entry("claude-fable-5", 900_000), tool_line)
        printed = self.run_mode(moot_hooks.mode_precompact,
                                {"session_id": self.session_id, "transcript_path": path})
        self.assertEqual(printed, [])

    def test_recovery_points_at_the_handoff_and_rearms_the_meter(self):
        with patch("moot_hooks.warn_competing_direct_entry"):
            printed = self.run_mode(moot_hooks.mode_session,
                                    {"session_id": self.session_id, "source": "compact"})
        self.assertEqual(len(printed), 1, printed)
        self.assertIn("session/%s/handoff" % self.session_id, printed[0])
        self.assertIn("derivesFrom", printed[0])
        state = moot_hooks.load_state(self.session_id)
        self.assertEqual(state.get("fired"), [])
        self.assertFalse(state.get("unknown_reported"))


if __name__ == "__main__":
    unittest.main()
