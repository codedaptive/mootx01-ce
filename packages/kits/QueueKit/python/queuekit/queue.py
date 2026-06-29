"""QueueKit facade per spec §3 — Python."""

from __future__ import annotations

import os
from typing import Callable, Iterable

from .filesystem_backend import FilesystemBackend, InvalidTerminalStatus
from .job import Job, ObservationStatus, ArtifactRef


class QueueKit:
    """Public facade. Methods: send/drain/watch/reply/in_flight/completed."""

    def __init__(self, root: str | os.PathLike, node_id: int = 1):
        self.backend = FilesystemBackend(root, node_id=node_id)

    def send(self, job: Job) -> None:
        self.backend.write(job)

    def drain(self) -> list[tuple[Job, str]]:
        return self.backend.drain_available()

    def watch(self, handler: Callable[[Job, str], None],
              poll_interval: float = 0.2) -> None:
        self.backend.watch(handler, poll_interval=poll_interval)

    def reply(self, job_id: str, status: ObservationStatus,
              artifacts: Iterable[ArtifactRef]) -> None:
        if not status.is_terminal():
            raise InvalidTerminalStatus(status)
        self.backend.complete(job_id, status, artifacts)

    def in_flight(self) -> list[Job]:
        return self.backend.in_flight()

    def completed(self, stream_id: str | None = None) -> list[Job]:
        return self.backend.completed(stream_id=stream_id)
