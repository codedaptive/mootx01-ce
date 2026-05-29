"""Tests for the Python FilesystemBackend (spec §5,6,8,9)."""

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
from queuekit.filesystem_backend import InvalidTerminalStatus, JobNotFound


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
