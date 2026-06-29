"""FilesystemBackend Python implementation per QUEUEKIT_SPEC §5,6,8,9.

POSIX maildir. Atomic rename(2) is the sole coordination primitive.
Zero required external dependencies (stdlib only). `watch()` uses a
polling loop; `watchdog` is optional and not required.
"""

from __future__ import annotations

import errno
import os
import time
from pathlib import Path
from typing import Callable, Iterable

from .job import (
    Job,
    SignalFile,
    ObservationStatus,
    ArtifactRef,
    HLC,
    encode_job,
    decode_job,
    encode_signal,
    filename_for_job,
    new_session_id,
)


STALE_TMP_SECONDS = 5 * 60


class QueueError(Exception):
    pass


class WriteFailed(QueueError):
    pass


class RenameFailed(QueueError):
    pass


class JobNotFound(QueueError):
    pass


class InvalidTerminalStatus(QueueError):
    pass


class InvalidIdentifier(QueueError):
    """A stream_id, job id, or other caller-supplied identifier contains a
    path separator, equals '.' or '..', or contains an ASCII control
    character. Planned security hardening — parity with Swift/Rust ports.
    """
    pass


class FilesystemBackend:
    """Per spec §5,6,8,9 — POSIX maildir."""

    def __init__(self, root: str | os.PathLike, node_id: int = 1):
        self.root = Path(root)
        self.node_id = node_id
        self._hlc_last_physical: int = 0
        self._hlc_last_logical: int = 0
        self._ensure_maildir()
        self._clean_stale_tmp()

    # --- maildir management ---

    @property
    def tmp_dir(self) -> Path: return self.root / "tmp"

    @property
    def new_dir(self) -> Path: return self.root / "new"

    @property
    def cur_dir(self) -> Path: return self.root / "cur"

    @property
    def done_dir(self) -> Path: return self.root / "done"

    def _ensure_maildir(self) -> None:
        for d in (self.tmp_dir, self.new_dir, self.cur_dir, self.done_dir):
            d.mkdir(parents=True, exist_ok=True)

    def _clean_stale_tmp(self) -> None:
        if not self.tmp_dir.exists():
            return
        cutoff = time.time() - STALE_TMP_SECONDS
        for entry in self.tmp_dir.iterdir():
            try:
                if entry.stat().st_mtime < cutoff:
                    entry.unlink()
            except OSError:
                pass

    # --- Identifier validation (planned security hardening, CAND-023) ---

    @staticmethod
    def _validate_identifier(id: str) -> None:
        """Validate that ``id`` is a safe single filesystem path component.

        An identifier used to build a queue path (stream_id, job id, or any
        caller-influenced component) must not contain characters that could
        escape the queue root via path traversal. Specifically, rejects:

        - empty strings
        - "." or ".." (dot directory components)
        - "/" or "\\" (POSIX and Windows path separators)
        - ASCII control characters 0x00–0x1F and 0x7F

        Legitimate identifiers — 32-char hex job ids, stream names like
        "encode" or "dreaming" — all pass. Enforces the same rule as the
        Swift and Rust ports. Raises ``InvalidIdentifier`` on rejection.
        """
        if not id:
            raise InvalidIdentifier("empty identifier")
        if id in (".", ".."):
            raise InvalidIdentifier(f"dot component: {id!r}")
        for ch in id:
            if ch in ("/", "\\"):
                raise InvalidIdentifier(f"path separator in {id!r}")
            v = ord(ch)
            if v <= 0x1F or v == 0x7F:
                raise InvalidIdentifier(f"control character in {id!r}")

    # --- HLC ---

    def _next_hlc(self) -> HLC:
        now_ms = int(time.time() * 1000)
        if now_ms > self._hlc_last_physical:
            self._hlc_last_physical = now_ms
            self._hlc_last_logical = 0
        else:
            self._hlc_last_logical += 1
        return HLC(
            physical_time=self._hlc_last_physical,
            logical_count=self._hlc_last_logical,
            node_id=self.node_id,
        )

    # --- write (spec §8) ---

    def write(self, job: Job) -> None:
        # Validate before any filesystem path construction.
        self._validate_identifier(job.stream_id)
        self._validate_identifier(job.id)
        encoded = encode_job(job)
        filename = filename_for_job(job)
        tmp_path = self.tmp_dir / filename
        new_path = self.new_dir / filename

        # Step 3: O_CREAT | O_EXCL — 0o600 (owner read/write only) to match
        # Swift and Rust FilesystemBackend behaviour; job files carry encoded
        # payloads (estate paths, content) and must not be group/world readable.
        try:
            fd = os.open(str(tmp_path),
                         os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
        except OSError as e:
            raise WriteFailed(f"open O_EXCL failed: {e}") from e
        try:
            # Step 4 + 5: write + fsync (before close)
            written = 0
            while written < len(encoded):
                w = os.write(fd, encoded[written:])
                if w <= 0:
                    raise WriteFailed("short write")
                written += w
            os.fsync(fd)
        finally:
            os.close(fd)  # Step 6

        # Step 7: rename tmp -> new
        try:
            os.rename(str(tmp_path), str(new_path))
        except FileNotFoundError:
            # ENOENT — recreate new/ and retry once per spec §8 step 7.
            self.new_dir.mkdir(parents=True, exist_ok=True)
            try:
                os.rename(str(tmp_path), str(new_path))
            except OSError as e:
                try: os.unlink(str(tmp_path))
                except OSError: pass
                raise WriteFailed(f"rename retry failed: {e}") from e
        except OSError as e:
            try: os.unlink(str(tmp_path))
            except OSError: pass
            if e.errno == errno.EXDEV:
                raise WriteFailed(
                    f"tmp and new on different filesystems: {e}") from e
            raise RenameFailed(f"{tmp_path} -> {new_path}: {e}") from e

        # Step 8: fsync the new/ directory
        try:
            dfd = os.open(str(self.new_dir), os.O_RDONLY)
            try: os.fsync(dfd)
            finally: os.close(dfd)
        except OSError:
            pass

    # --- drain_available (spec §9) ---

    def drain_available(self) -> list[tuple[Job, str]]:
        try:
            entries = sorted(os.listdir(self.new_dir))
        except OSError as e:
            raise QueueError(f"cannot list new/: {e}") from e

        claimed_files: list[str] = []
        for entry in entries:
            src = self.new_dir / entry
            dst = self.cur_dir / entry
            try:
                os.rename(str(src), str(dst))
                claimed_files.append(entry)
            except FileNotFoundError:
                continue
            except OSError as e:
                raise RenameFailed(f"{src} -> {dst}: {e}") from e

        results: list[tuple[Job, str]] = []
        for entry in claimed_files:
            path = self.cur_dir / entry
            try:
                data = path.read_bytes()
            except OSError:
                continue
            try:
                job = decode_job(data)
                results.append((job, new_session_id()))
            except Exception:
                # Decode failure per spec §9.3
                try:
                    os.rename(str(path), str(self.done_dir / entry))
                except OSError:
                    pass

        results.sort(key=lambda p: (
            p[0].submitted_at.physical_time,
            p[0].submitted_at.logical_count,
            p[0].submitted_at.node_id,
        ))
        return results

    # --- watch (spec §3) ---

    def watch(self, handler: Callable[[Job, str], None],
              poll_interval: float = 0.2) -> None:
        last_snapshot: set[str] = set()
        try:
            last_snapshot = set(os.listdir(self.new_dir))
        except OSError:
            pass
        # Initial drain of anything present
        for pair in self.drain_available():
            handler(pair[0], pair[1])

        while True:
            time.sleep(poll_interval)
            try:
                current = set(os.listdir(self.new_dir))
            except OSError:
                continue
            if current != last_snapshot:
                last_snapshot = current
                for pair in self.drain_available():
                    handler(pair[0], pair[1])

    # --- complete (spec §3, §6) ---

    def complete(self, job_id: str, status: ObservationStatus,
                 artifacts: Iterable[ArtifactRef]) -> None:
        # Validate before signal file path construction.
        self._validate_identifier(job_id)
        if not status.is_terminal():
            raise InvalidTerminalStatus(status)
        artifacts = list(artifacts)

        # Find the file in cur/
        match = None
        try:
            for entry in os.listdir(self.cur_dir):
                if entry.endswith(f"-{job_id}"):
                    match = entry
                    break
        except OSError as e:
            raise QueueError(f"cannot list cur/: {e}") from e
        if match is None:
            raise JobNotFound(job_id)

        # Write signal file BEFORE renaming job per spec §6
        completed = self._next_hlc()
        signal = SignalFile(
            job_id=job_id, status=status,
            artifacts=artifacts, completed_at=completed)
        signal_data = encode_signal(signal)
        signal_tmp = self.tmp_dir / f"{job_id}.signal"
        signal_final = self.done_dir / f"{job_id}.signal"
        # 0o600 — owner read/write only, parity with Swift/Rust ports and job files.
        fd = os.open(str(signal_tmp),
                     os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
        try:
            os.write(fd, signal_data)
            os.fsync(fd)
        finally:
            os.close(fd)
        os.rename(str(signal_tmp), str(signal_final))

        # Now move the job file
        try:
            os.rename(str(self.cur_dir / match),
                      str(self.done_dir / match))
        except OSError as e:
            raise RenameFailed(f"complete rename: {e}") from e

    # --- inFlight / completed ---

    def in_flight(self) -> list[Job]:
        return self._list_jobs(self.cur_dir, stream_id=None)

    def completed(self, stream_id: str | None = None) -> list[Job]:
        return self._list_jobs(self.done_dir, stream_id=stream_id)

    def _list_jobs(self, dir: Path, stream_id: str | None) -> list[Job]:
        jobs: list[Job] = []
        try:
            entries = sorted(os.listdir(dir))
        except OSError:
            return []
        for entry in entries:
            if entry.endswith(".signal"):
                continue
            path = dir / entry
            try:
                data = path.read_bytes()
                job = decode_job(data)
            except Exception:
                continue
            if stream_id is not None and job.stream_id != stream_id:
                continue
            jobs.append(job)
        return jobs
