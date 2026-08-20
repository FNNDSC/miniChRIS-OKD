"""
Test-data generation and output verification.

The payload is generated non-PHI text stamped per run — a stale output from an
earlier run can never produce a false pass because the expected sha256 is
computed from this run's bytes at generation time.
"""

from __future__ import annotations

import hashlib
from dataclasses import dataclass


@dataclass(frozen=True)
class Payload:
    name: str
    content: bytes
    sha256: str


def sha256_hex(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def make_payload(stamp: str) -> Payload:
    text = (
        "ChRIS OKD harness functional smoke test payload (issue #131).\n"
        "Synthetic non-PHI content — safe to store, copy, and delete.\n"
        f"run stamp: {stamp}\n"
        "The ds plugin must return these bytes unchanged; the sha256 of this\n"
        "exact content is the pass/fail criterion.\n"
    )
    content = text.encode()
    return Payload(name="input.txt", content=content, sha256=sha256_hex(content))


def compare(payload: Payload, downloaded: bytes) -> str | None:
    """None when the downloaded bytes match the payload, else a diagnosis."""
    actual = sha256_hex(downloaded)
    if actual == payload.sha256:
        return None
    return (f"checksum mismatch: expected sha256 {payload.sha256} "
            f"({len(payload.content)} B), got {actual} ({len(downloaded)} B)")
