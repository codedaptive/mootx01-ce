"""Python QueueKit wire-format, facade, and FilesystemBackend tests (spec §5,6,8,9).

Covers wire-format helpers (base64url, HLC format, filename spec), the QueueKit
facade (send, drain, reply), and FilesystemBackend operations (maildir init,
drain ordering, stale-tmp cleanup).
"""

from __future__ import annotations

import json
import os
import tempfile
from pathlib import Path

import pytest

from queuekit import (
    Job,
    HLC,
    ArtifactRef,
    ObservationStatus,
    QueueKit,
    FilesystemBackend,
    base64url_encode,
    base64url_decode,
    sortable_hlc,
    filename_for_job,
    encode_job,
    decode_job,
)
from queuekit.filesystem_backend import InvalidTerminalStatus, JobNotFound, InvalidIdentifier


def make_job(
    job_id: str = "deadbeef000000000000000000000000",
    stream_id: str = "x",
    phys: int = 1, logical: int = 0, node: int = 1,
    payload: bytes = b"",
    extensions: dict | None = None,
) -> Job:
    return Job(
        id=job_id,
        stream_id=stream_id,
        submitted_at=HLC(physical_time=phys, logical_count=logical, node_id=node),
        priority=50,
        payload=payload,
        extensions=extensions or {},
    )


def test_base64url_no_padding():
    cases = [(b"", ""), (b"\xff", "_w"), (b"\xfb\xff", "-_8")]
    for data, expected in cases:
        assert base64url_encode(data) == expected
        assert base64url_decode(expected) == data


def test_sortable_hlc_format():
    h = HLC(physical_time=1747526400000, logical_count=0,
            node_id=-559038737)  # 0xDEADBEEF as signed int32
    assert sortable_hlc(h) == "0001747526400000-00000000-3735928559"


def test_filename_matches_spec():
    job = make_job(
        job_id="deadbeef000000000000000000000000",
        stream_id="my-stream",
        phys=1747526400000, logical=0, node=-559038737,
    )
    assert filename_for_job(job) == (
        "0001747526400000-00000000-3735928559-my-stream-"
        "deadbeef000000000000000000000000")


def test_job_round_trip():
    j = make_job(extensions={"k": "v"})
    encoded = encode_job(j)
    decoded = decode_job(encoded)
    assert decoded.id == j.id
    assert decoded.stream_id == j.stream_id
    assert decoded.submitted_at == j.submitted_at
    assert decoded.priority == j.priority
    assert decoded.payload == j.payload
    assert decoded.extensions == j.extensions


def test_maildir_init_creates_four():
    with tempfile.TemporaryDirectory() as tmp:
        QueueKit(tmp)
        for d in ("tmp", "new", "cur", "done"):
            assert (Path(tmp) / d).is_dir()


def test_send_then_drain():
    with tempfile.TemporaryDirectory() as tmp:
        kit = QueueKit(tmp)
        kit.send(make_job(payload=b"hi"))
        claimed = kit.drain()
        assert len(claimed) == 1
        assert claimed[0][0].payload == b"hi"
        # state transition
        assert len(list((Path(tmp) / "new").iterdir())) == 0
        assert len(list((Path(tmp) / "cur").iterdir())) == 1


def test_reply_writes_signal_before_rename():
    with tempfile.TemporaryDirectory() as tmp:
        kit = QueueKit(tmp)
        job = make_job()
        kit.send(job)
        kit.drain()
        kit.reply(job.id, ObservationStatus.DONE, [])
        assert (Path(tmp) / "done" / f"{job.id}.signal").exists()


def test_reply_rejects_non_terminal():
    with tempfile.TemporaryDirectory() as tmp:
        kit = QueueKit(tmp)
        with pytest.raises(InvalidTerminalStatus):
            kit.reply("x", ObservationStatus.RUNNING, [])


def test_reply_not_found():
    with tempfile.TemporaryDirectory() as tmp:
        kit = QueueKit(tmp)
        with pytest.raises(JobNotFound):
            kit.reply("deadbeef" * 4, ObservationStatus.DONE, [])


def test_drain_in_hlc_order():
    with tempfile.TemporaryDirectory() as tmp:
        kit = QueueKit(tmp)
        later = make_job(job_id="b" * 32, phys=200)
        earlier = make_job(job_id="a" * 32, phys=100)
        kit.send(later)
        kit.send(earlier)
        claimed = kit.drain()
        assert len(claimed) == 2
        assert claimed[0][0].submitted_at.physical_time == 100
        assert claimed[1][0].submitted_at.physical_time == 200


def test_stale_tmp_cleanup_on_reinit():
    with tempfile.TemporaryDirectory() as tmp:
        kit = FilesystemBackend(tmp)
        stale = Path(tmp) / "tmp" / "stale-file"
        stale.write_bytes(b"stale")
        # Backdate
        old = (Path(tmp).stat().st_mtime) - 600
        os.utime(str(stale), (old, old))
        # Re-init
        FilesystemBackend(tmp)
        assert not stale.exists()


def test_job_file_mode_is_0o600():
    """Job files must be owner read/write only (0o600), matching Swift/Rust ports.

    Job files carry encoded payloads (estate paths, content) and must not be
    group- or world-readable. This test verifies the file mode after write()
    creates the job in new/ via atomic rename from tmp/.
    """
    with tempfile.TemporaryDirectory() as tmp:
        backend = FilesystemBackend(tmp)
        job = make_job(payload=b"secret-data")
        backend.write(job)
        # Find the file in new/
        files = list((Path(tmp) / "new").iterdir())
        assert len(files) == 1, "expected one job file in new/"
        mode = files[0].stat().st_mode & 0o777
        assert mode == 0o600, f"job file mode must be 0o600, got 0o{mode:o}"


def test_signal_file_mode_is_0o600():
    """Signal files must be owner read/write only (0o600), matching job files.

    Signal files are written by complete() before the job is moved to done/.
    They carry completion metadata and must not be group- or world-readable.
    """
    with tempfile.TemporaryDirectory() as tmp:
        backend = FilesystemBackend(tmp)
        job = make_job()
        backend.write(job)
        backend.drain_available()
        backend.complete(job.id, ObservationStatus.DONE, [])
        signal = Path(tmp) / "done" / f"{job.id}.signal"
        assert signal.exists(), "signal file must exist after complete()"
        mode = signal.stat().st_mode & 0o777
        assert mode == 0o600, f"signal file mode must be 0o600, got 0o{mode:o}"


# --- Identifier validation (CAND-023 — planned security hardening) ---

def make_unsafe_job(stream_id: str = "encode", job_id: str = "abc123") -> Job:
    """Build a minimal Job with the given raw stream_id and job_id strings."""
    return Job(
        id=job_id,
        stream_id=stream_id,
        submitted_at=HLC(physical_time=1, logical_count=0, node_id=1),
        priority=50,
        payload=b"",
        extensions={},
    )


def test_rejects_dotdot_stream_id():
    # ".." as a stream_id would escape the queue root via path traversal
    # when embedded in the job filename.
    with tempfile.TemporaryDirectory() as tmp:
        backend = FilesystemBackend(tmp)
        job = make_unsafe_job(stream_id="..")
        with pytest.raises(InvalidIdentifier):
            backend.write(job)


def test_rejects_dotdot_job_id():
    # ".." as a job id would escape the queue root in signal file paths
    # (e.g. "..".signal resolved against done/).
    with tempfile.TemporaryDirectory() as tmp:
        backend = FilesystemBackend(tmp)
        job = make_unsafe_job(job_id="..")
        with pytest.raises(InvalidIdentifier):
            backend.write(job)


def test_rejects_forward_slash_in_stream_id():
    # "/" injects a directory separator into the filename component.
    with tempfile.TemporaryDirectory() as tmp:
        backend = FilesystemBackend(tmp)
        job = make_unsafe_job(stream_id="evil/stream")
        with pytest.raises(InvalidIdentifier):
            backend.write(job)


def test_rejects_backslash_in_job_id():
    # "\\" is the Windows path separator; reject to maintain cross-platform safety.
    with tempfile.TemporaryDirectory() as tmp:
        backend = FilesystemBackend(tmp)
        job = make_unsafe_job(job_id="bad\\id")
        with pytest.raises(InvalidIdentifier):
            backend.write(job)


def test_rejects_absolute_path_as_stream_id():
    # An absolute path starts with "/" — caught by the separator check.
    with tempfile.TemporaryDirectory() as tmp:
        backend = FilesystemBackend(tmp)
        job = make_unsafe_job(stream_id="/etc/passwd")
        with pytest.raises(InvalidIdentifier):
            backend.write(job)


def test_rejects_control_character_in_job_id():
    # Control characters (0x00–0x1F) produce problematic filenames.
    with tempfile.TemporaryDirectory() as tmp:
        backend = FilesystemBackend(tmp)
        job = make_unsafe_job(job_id="bad\x01id")
        with pytest.raises(InvalidIdentifier):
            backend.write(job)


def test_accepts_legitimate_identifiers():
    # 32-char hex job ids and kebab-case stream names must not be rejected.
    with tempfile.TemporaryDirectory() as tmp:
        backend = FilesystemBackend(tmp)
        job = make_unsafe_job(
            stream_id="encode-corpus",
            job_id="a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4",
        )
        backend.write(job)  # must not raise
        results = backend.drain_available()
        assert len(results) == 1


def test_rejects_dotdot_job_id_on_complete():
    # complete() constructs a signal file path from the job id;
    # ".." would escape done/.
    with tempfile.TemporaryDirectory() as tmp:
        backend = FilesystemBackend(tmp)
        with pytest.raises(InvalidIdentifier):
            backend.complete("..", ObservationStatus.DONE, [])


def test_rejects_forward_slash_job_id_on_complete():
    with tempfile.TemporaryDirectory() as tmp:
        backend = FilesystemBackend(tmp)
        with pytest.raises(InvalidIdentifier):
            backend.complete("a/b", ObservationStatus.DONE, [])
