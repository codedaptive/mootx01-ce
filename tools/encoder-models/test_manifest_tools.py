#!/usr/bin/env python3
"""Offline tests for encoder artifact manifest coverage and digest gates."""

from __future__ import annotations

import hashlib
import json
import struct
import tempfile
import unittest
from pathlib import Path

from manifest_tools import (
    DIRECTORY_HASH_DOMAIN,
    ManifestError,
    _main,
    cross_encoder_record,
    directory_sha256,
    sha256_file,
    verify_manifest_files,
    verify_source_manifest,
)


IDENTITY = {
    "model_id": "fixture-w60",
    "model_version": "a" * 40,
    "dim": 3,
    "pooling": "cls",
    "query_prefix": "query: ",
    "doc_prefix": "",
    "window_words": 60,
    "overlap_divisor": 2,
    "max_spans": 32,
    "max_sequence": 8,
}


class ManifestToolsTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory(prefix="encoder-manifest-tests-")
        self.root = Path(self.temporary.name)
        for name, content in {
            "config.json": b"{}\n",
            "tokenizer.json": b'{"version":"1"}\n',
            "model.safetensors": b"fixture weights",
            "vocab.txt": b"[PAD]\n[UNK]\n[CLS]\n[SEP]\n",
        }.items():
            (self.root / name).write_bytes(content)

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def manifest(self) -> dict[str, object]:
        files = [
            {"path": name, "sha256": sha256_file(self.root / name)}
            for name in ("config.json", "tokenizer.json", "model.safetensors", "vocab.txt")
        ]
        return {
            **IDENTITY,
            "tokenizer_hash": sha256_file(self.root / "vocab.txt"),
            "files": files,
            "ext": {
                "hf_repo": "Fixture/source-model",
                "hf_revision": "a" * 40,
            },
        }

    def write_manifest(self, value: dict[str, object]) -> Path:
        path = self.root / "manifest.json"
        path.write_text(json.dumps(value))
        return path

    def cross_manifest(self) -> dict[str, object]:
        files = [
            {"path": name, "sha256": sha256_file(self.root / name)}
            for name in ("config.json", "tokenizer.json", "model.safetensors", "vocab.txt")
        ]
        return cross_encoder_record(
            model_id="fixture-cross-v1",
            revision="b" * 40,
            max_sequence=8,
            pool=5,
            head=3,
            spans=2,
            rrf_k=60,
            tokenizer_hash=sha256_file(self.root / "vocab.txt"),
            files=files,
            ext={"hf_repo": "owner/cross", "hf_revision": "b" * 40},
        )

    def test_cross_encoder_manifest_verifies_with_its_own_identity(self) -> None:
        path = self.root / "cross.json"
        path.write_text(json.dumps(self.cross_manifest()))
        identity = {
            "kind": "cross_encoder",
            "model_id": "fixture-cross-v1",
            "model_version": "b" * 40,
            "max_sequence": 8,
            "pool": 5,
            "head": 3,
            "spans": 2,
            "rrf_k": 60,
        }
        verify_manifest_files(path, self.root, "linux", expected_identity=identity)
        # An encoder identity never matches a cross-encoder record.
        with self.assertRaises(ManifestError):
            verify_manifest_files(path, self.root, "linux", expected_identity=IDENTITY)

    def test_cross_encoder_record_rejects_head_above_pool(self) -> None:
        with self.assertRaises(ManifestError):
            cross_encoder_record(
                model_id="x", revision="b" * 40, max_sequence=8, pool=3, head=5, spans=1, rrf_k=60,
                tokenizer_hash="0" * 64, files=[], ext={},
            )

    def test_complete_linux_manifest_verifies(self) -> None:
        manifest = self.write_manifest(self.manifest())
        verify_manifest_files(manifest, self.root, "linux", IDENTITY)

    def test_missing_vocab_entry_is_rejected(self) -> None:
        value = self.manifest()
        value["files"] = [entry for entry in value["files"] if entry["path"] != "vocab.txt"]  # type: ignore[index]
        with self.assertRaisesRegex(ManifestError, "coverage"):
            verify_manifest_files(self.write_manifest(value), self.root, "linux", IDENTITY)

    def test_wrong_digest_is_rejected(self) -> None:
        value = self.manifest()
        value["files"][0]["sha256"] = "0" * 64  # type: ignore[index]
        with self.assertRaisesRegex(ManifestError, "sha256 mismatch"):
            verify_manifest_files(self.write_manifest(value), self.root, "linux", IDENTITY)

    def test_wrong_identity_is_rejected(self) -> None:
        value = self.manifest()
        value["pooling"] = "mean"
        with self.assertRaisesRegex(ManifestError, "pooling mismatch"):
            verify_manifest_files(self.write_manifest(value), self.root, "linux", IDENTITY)

    def test_complete_source_manifest_verifies_repo_revision_and_files(self) -> None:
        manifest = self.write_manifest(self.manifest())
        verified = verify_source_manifest(
            manifest,
            self.root,
            expected_identity=IDENTITY,
            hf_repo="Fixture/source-model",
            hf_revision="a" * 40,
        )
        self.assertEqual(verified["model_version"], "a" * 40)

    def test_source_manifest_wrong_repo_is_rejected(self) -> None:
        manifest = self.write_manifest(self.manifest())
        with self.assertRaisesRegex(ManifestError, "hf_repo mismatch"):
            verify_source_manifest(
                manifest,
                self.root,
                expected_identity=IDENTITY,
                hf_repo="Fixture/other-model",
                hf_revision="a" * 40,
            )

    def test_source_manifest_wrong_revision_is_rejected(self) -> None:
        manifest = self.write_manifest(self.manifest())
        with self.assertRaisesRegex(ManifestError, "full revision"):
            verify_source_manifest(
                manifest,
                self.root,
                expected_identity=IDENTITY,
                hf_repo="Fixture/source-model",
                hf_revision="b" * 40,
            )

    def test_source_manifest_requires_full_revision(self) -> None:
        manifest = self.write_manifest(self.manifest())
        with self.assertRaisesRegex(ManifestError, "full lowercase 40-character"):
            verify_source_manifest(
                manifest,
                self.root,
                expected_identity=IDENTITY,
                hf_repo="Fixture/source-model",
                hf_revision="main",
            )

    def test_non_hex_pending_digest_is_rejected(self) -> None:
        value = self.manifest()
        value["files"][0]["sha256"] = "PENDING"  # type: ignore[index]
        with self.assertRaisesRegex(ManifestError, "not 64 lowercase"):
            verify_manifest_files(self.write_manifest(value), self.root, "linux", IDENTITY)

    def test_directory_hash_uses_framed_relative_paths_and_bytes(self) -> None:
        artifact = self.root / "Fixture.aimodel"
        nested = artifact / "sub"
        nested.mkdir(parents=True)
        (artifact / "same").write_bytes(b"one")
        (nested / "same").write_bytes(b"two")

        expected = hashlib.sha256(DIRECTORY_HASH_DOMAIN)
        for relative, content in (("same", b"one"), ("sub/same", b"two")):
            encoded = relative.encode("utf-8")
            expected.update(struct.pack(">Q", len(encoded)))
            expected.update(encoded)
            expected.update(struct.pack(">Q", len(content)))
            expected.update(content)
        self.assertEqual(directory_sha256(artifact), expected.hexdigest())


_CROSS_ARGS = [
    "--model-id", "fixture-cross-v1",
    "--hf-repo", "owner/cross",
    "--revision", "b" * 40,
    "--max-sequence", "8",
    "--pool", "5",
    "--head", "3",
    "--spans", "2",
    "--rrf-k", "60",
]


class VerifyCrossSubcommandTests(unittest.TestCase):
    """Tests for the `verify-cross` CLI subcommand. — W78-5"""

    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory(prefix="verify-cross-tests-")
        self.root = Path(self.temporary.name)
        for name, content in {
            "config.json": b"{}\n",
            "tokenizer.json": b'{"version":"1"}\n',
            "model.safetensors": b"fixture weights",
            "vocab.txt": b"[PAD]\n[UNK]\n[CLS]\n[SEP]\n",
        }.items():
            (self.root / name).write_bytes(content)

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def _cross_manifest_path(self) -> Path:
        files = [
            {"path": name, "sha256": sha256_file(self.root / name)}
            for name in ("config.json", "tokenizer.json", "model.safetensors", "vocab.txt")
        ]
        record = cross_encoder_record(
            model_id="fixture-cross-v1",
            revision="b" * 40,
            max_sequence=8,
            pool=5,
            head=3,
            spans=2,
            rrf_k=60,
            tokenizer_hash=sha256_file(self.root / "vocab.txt"),
            files=files,
            ext={"hf_repo": "owner/cross", "hf_revision": "b" * 40},
        )
        path = self.root / "cross.json"
        path.write_text(json.dumps(record))
        return path

    def test_valid_cross_manifest_exits_zero(self) -> None:
        manifest = self._cross_manifest_path()
        rc = _main([
            "verify-cross",
            "--manifest", str(manifest),
            "--root", str(self.root),
            "--platform", "linux",
            *_CROSS_ARGS,
        ])
        self.assertEqual(rc, 0)

    def test_wrong_model_id_is_rejected(self) -> None:
        # _main catches ManifestError and returns 1; assertRaises would not fire.
        manifest = self._cross_manifest_path()
        rc = _main([
            "verify-cross",
            "--manifest", str(manifest),
            "--root", str(self.root),
            "--platform", "linux",
            "--model-id", "other-model",
            "--hf-repo", "owner/cross",
            "--revision", "b" * 40,
            "--max-sequence", "8",
            "--pool", "5",
            "--head", "3",
            "--spans", "2",
            "--rrf-k", "60",
        ])
        self.assertEqual(rc, 1, "verify-cross must return 1 when model_id mismatches")

    def test_wrong_digest_is_rejected(self) -> None:
        # _main catches ManifestError and returns 1; assertRaises would not fire.
        manifest = self._cross_manifest_path()
        # Corrupt one file after recording the manifest.
        (self.root / "config.json").write_bytes(b"changed\n")
        rc = _main([
            "verify-cross",
            "--manifest", str(manifest),
            "--root", str(self.root),
            "--platform", "linux",
            *_CROSS_ARGS,
        ])
        self.assertEqual(rc, 1, "verify-cross must return 1 when a file digest mismatches")


class RecordLinuxCrossSubcommandTests(unittest.TestCase):
    """Tests for the `record-linux-cross` CLI subcommand. — W78-5"""

    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory(prefix="record-linux-cross-tests-")
        self.root = Path(self.temporary.name)
        for name, content in {
            "config.json": b"{}\n",
            "tokenizer.json": b'{"version":"1"}\n',
            "model.safetensors": b"fixture weights",
            "vocab.txt": b"[PAD]\n[UNK]\n[CLS]\n[SEP]\n",
        }.items():
            (self.root / name).write_bytes(content)

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def test_record_linux_cross_writes_and_self_verifies(self) -> None:
        manifest = self.root / "out.json"
        rc = _main([
            "record-linux-cross",
            "--manifest", str(manifest),
            "--root", str(self.root),
            *_CROSS_ARGS,
        ])
        self.assertEqual(rc, 0)
        self.assertTrue(manifest.exists())
        data = json.loads(manifest.read_text())
        self.assertEqual(data["kind"], "cross_encoder")
        self.assertEqual(data["model_id"], "fixture-cross-v1")
        self.assertEqual(data["model_version"], "b" * 40)
        self.assertEqual(data["pool"], 5)
        self.assertEqual(data["head"], 3)
        self.assertEqual(len(data["files"]), 4)
        # tokenizer_hash must equal sha256 of vocab.txt.
        expected_vocab_hash = sha256_file(self.root / "vocab.txt")
        self.assertEqual(data["tokenizer_hash"], expected_vocab_hash)

    def test_record_linux_cross_written_manifest_passes_verify_cross(self) -> None:
        """The manifest produced by `record-linux-cross` must pass `verify-cross`."""
        manifest = self.root / "round_trip.json"
        _main([
            "record-linux-cross",
            "--manifest", str(manifest),
            "--root", str(self.root),
            *_CROSS_ARGS,
        ])
        rc = _main([
            "verify-cross",
            "--manifest", str(manifest),
            "--root", str(self.root),
            "--platform", "linux",
            *_CROSS_ARGS,
        ])
        self.assertEqual(rc, 0)


class InstallerPinParityTests(unittest.TestCase):
    """Assert that the SHA-256 literals pinned in scripts/install.ps1 match
    tools/encoder-models/encoder-models-linux.json.  A model bump that updates
    the manifest but forgets to update the installer script would silently
    leave Windows users unable to install; this test catches that at CI time.

    Fails on pre-fix code because install.ps1 contained no pinned digest
    constants at all — the $EncoderModelDigests hashtable was absent.
    """

    # Repo root relative to this file: tools/encoder-models/ -> up two levels
    _REPO_ROOT = Path(__file__).parent.parent.parent
    _MANIFEST = _REPO_ROOT / "tools" / "encoder-models" / "encoder-models-linux.json"
    _INSTALLER = _REPO_ROOT / "scripts" / "install.ps1"

    def _manifest_digests(self) -> dict[str, str]:
        """Return {filename: sha256hex} from the linux manifest."""
        data = json.loads(self._MANIFEST.read_text())
        return {entry["path"]: entry["sha256"] for entry in data["files"]}

    def _installer_digests(self) -> dict[str, str]:
        """Parse the $EncoderModelDigests hashtable from install.ps1.

        Looks for lines of the form (with optional surrounding whitespace):
            "config.json"       = "4e519..."
        inside the hashtable block.
        """
        import re
        text = self._INSTALLER.read_text(encoding="utf-8-sig")
        # SECURITY: literal string parse — no eval; regex matches quoted kv pairs.
        pattern = re.compile(
            r'"(?P<file>[^"]+)"\s*=\s*"(?P<digest>[0-9a-f]{64})"'
        )
        results: dict[str, str] = {}
        in_block = False
        for line in text.splitlines():
            if "$EncoderModelDigests" in line and "@{" in line:
                in_block = True
            if in_block:
                m = pattern.search(line)
                if m:
                    results[m.group("file")] = m.group("digest")
                if "}" in line and in_block and results:
                    # closing brace of the hashtable
                    if not ("@{" in line):
                        in_block = False
        return results

    def test_installer_pins_all_four_model_files(self) -> None:
        """install.ps1 must pin exactly the four required model file digests."""
        pinned = self._installer_digests()
        required = {"config.json", "tokenizer.json", "model.safetensors", "vocab.txt"}
        missing = required - pinned.keys()
        self.assertFalse(
            missing,
            f"install.ps1 is missing pinned digests for: {missing}",
        )

    def test_installer_digests_match_manifest(self) -> None:
        """Every digest pinned in install.ps1 must equal the manifest entry."""
        manifest = self._manifest_digests()
        installer = self._installer_digests()
        for filename, expected in manifest.items():
            if filename not in installer:
                continue  # covered by test_installer_pins_all_four_model_files
            self.assertEqual(
                installer[filename],
                expected,
                f"Digest mismatch for {filename}: install.ps1 has {installer[filename]!r}, "
                f"manifest has {expected!r}",
            )


class CrossEncoderManifestParityTests(unittest.TestCase):
    """Assert that `cross-encoder-models-linux.json` is consistent with the
    packaged profile (`CrossEncoderProfile.minilmL6`) declared in code.
    Mirrors `InstallerPinParityTests` for the cross-encoder manifest — I78-2.

    Catches a version bump that updates the manifest but forgets to update
    the Swift/Rust profile constant (or vice versa).
    """

    # Model id pinned in the code profile.
    _PROFILE_MODEL_ID = "ms-marco-minilm-l6-cross-v1"

    _REPO_ROOT = Path(__file__).parent.parent.parent
    _LINUX_MANIFEST = (
        _REPO_ROOT / "tools" / "encoder-models" / "cross-encoder-models-linux.json"
    )
    _APPLE_MANIFEST = (
        _REPO_ROOT / "tools" / "encoder-models" / "cross-encoder-models-apple.json"
    )

    def _load_manifest(self, path: Path) -> dict:
        return json.loads(path.read_text())

    def test_linux_manifest_exists_and_has_cross_encoder_kind(self) -> None:
        data = self._load_manifest(self._LINUX_MANIFEST)
        self.assertEqual(
            data.get("kind"),
            "cross_encoder",
            f"{self._LINUX_MANIFEST.name}: expected kind='cross_encoder', got {data.get('kind')!r}",
        )

    def test_apple_manifest_exists_and_has_cross_encoder_kind(self) -> None:
        data = self._load_manifest(self._APPLE_MANIFEST)
        self.assertEqual(
            data.get("kind"),
            "cross_encoder",
            f"{self._APPLE_MANIFEST.name}: expected kind='cross_encoder', got {data.get('kind')!r}",
        )

    def _code_profile_model_version(self) -> str:
        """Read the 40-char model version from the Swift CrossEncoderProfile source.

        Parses `modelVersion: "..."` from CrossEncoderProfile.swift so the test
        reads from one authoritative source instead of duplicating the constant.
        """
        import re
        swift_path = (
            self._REPO_ROOT
            / "packages" / "kits" / "CorpusKit"
            / "Sources" / "CorpusKit" / "Encoder"
            / "CrossEncoderProfile.swift"
        )
        source = swift_path.read_text()
        match = re.search(r'modelVersion:\s*"([0-9a-f]{40})"', source)
        self.assertIsNotNone(match, f"Cannot find modelVersion in {swift_path}")
        return match.group(1)  # type: ignore[union-attr]

    def test_linux_manifest_model_version_matches_code_profile(self) -> None:
        """model_version in the Linux manifest must equal the full 40-char hash
        in `CrossEncoderProfile.minilmL6.modelVersion`."""
        data = self._load_manifest(self._LINUX_MANIFEST)
        self.assertEqual(
            data.get("model_version"),
            self._code_profile_model_version(),
            f"{self._LINUX_MANIFEST.name}: model_version mismatch with code profile",
        )

    def test_apple_manifest_model_version_matches_code_profile(self) -> None:
        """model_version in the Apple manifest must equal the full 40-char hash
        in `CrossEncoderProfile.minilmL6.modelVersion`."""
        data = self._load_manifest(self._APPLE_MANIFEST)
        self.assertEqual(
            data.get("model_version"),
            self._code_profile_model_version(),
            f"{self._APPLE_MANIFEST.name}: model_version mismatch with code profile",
        )

    def test_linux_manifest_model_id_matches_code_profile(self) -> None:
        data = self._load_manifest(self._LINUX_MANIFEST)
        self.assertEqual(
            data.get("model_id"),
            self._PROFILE_MODEL_ID,
            f"{self._LINUX_MANIFEST.name}: model_id mismatch with code profile",
        )

    def test_manifests_agree_on_model_version(self) -> None:
        """Both Apple and Linux manifests must carry the same model_version."""
        linux = self._load_manifest(self._LINUX_MANIFEST)
        apple = self._load_manifest(self._APPLE_MANIFEST)
        self.assertEqual(
            linux.get("model_version"),
            apple.get("model_version"),
            "Cross-encoder manifests disagree on model_version",
        )


if __name__ == "__main__":
    unittest.main()
