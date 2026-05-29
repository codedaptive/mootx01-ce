"""Wire format types and encoders per QUEUEKIT_SPEC §6 and §7.

Byte-identical to the Swift implementation. Compatible with the
shared conformance fixtures generated from Swift.
"""

from __future__ import annotations

import base64
import json
import uuid
from dataclasses import dataclass, field
from enum import Enum
from typing import Any


class ObservationStatus(str, Enum):
    """Per spec §7. Raw values match the signal file `status` field."""

    RUNNING = "running"
    DONE = "done"
    DONE_WITH_CONCERNS = "done_with_concerns"
    NEEDS_CONTEXT = "needs_context"
    BLOCKED = "blocked"

    def is_terminal(self) -> bool:
        return self is not ObservationStatus.RUNNING


@dataclass(frozen=True)
class HLC:
    """Hybrid Logical Clock — must match SubstrateLib HLC bit-for-bit."""

    physical_time: int
    logical_count: int
    node_id: int  # signed Int32

    def __lt__(self, other: "HLC") -> bool:
        return (
            self.physical_time,
            self.logical_count,
            self.node_id,
        ) < (
            other.physical_time,
            other.logical_count,
            other.node_id,
        )


@dataclass(frozen=True)
class ArtifactRef:
    """Tagged union encoded as {"type": ..., "value": ...} per spec §6."""

    type: str  # "file_path" | "commit_hash" | "signal_file" | "trajectory_step_id"
    value: str

    def to_wire(self) -> dict[str, str]:
        return {"type": self.type, "value": self.value}


@dataclass
class Job:
    id: str
    stream_id: str
    submitted_at: HLC
    priority: int
    payload: bytes
    extensions: dict[str, Any] = field(default_factory=dict)


@dataclass
class SignalFile:
    job_id: str
    status: ObservationStatus
    artifacts: list[ArtifactRef]
    completed_at: HLC


# -----------------------------------------------------------------
# base64url (RFC 4648 §5), no padding
# -----------------------------------------------------------------


def base64url_encode(data: bytes) -> str:
    s = base64.urlsafe_b64encode(data).decode("ascii")
    return s.rstrip("=")


def base64url_decode(s: str) -> bytes:
    pad = (-len(s)) % 4
    return base64.urlsafe_b64decode(s + ("=" * pad))


# -----------------------------------------------------------------
# Filename encoding (spec §6)
# -----------------------------------------------------------------


def sortable_hlc(hlc: HLC) -> str:
    phys = f"{hlc.physical_time:016d}"
    logical = f"{hlc.logical_count:08d}"
    # nodeID rendered as unsigned decimal of the Int32 signed value
    unsigned = hlc.node_id & 0xFFFFFFFF
    node = f"{unsigned:010d}"
    return f"{phys}-{logical}-{node}"


def filename_for_job(job: Job) -> str:
    return f"{sortable_hlc(job.submitted_at)}-{job.stream_id}-{job.id}"


# -----------------------------------------------------------------
# JSON encoding (spec §6)
# -----------------------------------------------------------------


def _hlc_dict(hlc: HLC) -> dict[str, int]:
    return {
        "physical_time": hlc.physical_time,
        "logical_count": hlc.logical_count,
        "node_id": hlc.node_id & 0xFFFFFFFF,
    }


def _hlc_from_dict(d: dict[str, int]) -> HLC:
    unsigned = int(d["node_id"])
    signed = unsigned if unsigned < 0x80000000 else unsigned - 0x1_0000_0000
    return HLC(
        physical_time=int(d["physical_time"]),
        logical_count=int(d["logical_count"]),
        node_id=signed,
    )


def _canonical_json(obj: Any) -> bytes:
    """Sorted-keys, no whitespace, no escaped slashes — matches Swift
    JSONEncoder(.sortedKeys, .withoutEscapingSlashes)."""
    return json.dumps(
        obj,
        sort_keys=True,
        separators=(",", ":"),
        ensure_ascii=False,
    ).encode("utf-8")


def encode_job(job: Job) -> bytes:
    obj = {
        "id": job.id,
        "stream_id": job.stream_id,
        "submitted_at": _hlc_dict(job.submitted_at),
        "priority": job.priority,
        "payload": base64url_encode(job.payload),
        "extensions": job.extensions,
    }
    return _canonical_json(obj)


def decode_job(data: bytes) -> Job:
    obj = json.loads(data)
    return Job(
        id=obj["id"],
        stream_id=obj["stream_id"],
        submitted_at=_hlc_from_dict(obj["submitted_at"]),
        priority=int(obj["priority"]),
        payload=base64url_decode(obj["payload"]),
        extensions=obj.get("extensions", {}),
    )


def encode_signal(sig: SignalFile) -> bytes:
    obj = {
        "job_id": sig.job_id,
        "status": sig.status.value,
        "artifacts": [a.to_wire() for a in sig.artifacts],
        "completed_at": _hlc_dict(sig.completed_at),
    }
    return _canonical_json(obj)


def decode_signal(data: bytes) -> SignalFile:
    obj = json.loads(data)
    return SignalFile(
        job_id=obj["job_id"],
        status=ObservationStatus(obj["status"]),
        artifacts=[ArtifactRef(a["type"], a["value"])
                   for a in obj["artifacts"]],
        completed_at=_hlc_from_dict(obj["completed_at"]),
    )


def new_job_id() -> str:
    return uuid.uuid4().hex


def new_session_id() -> str:
    return str(uuid.uuid4()).lower()
