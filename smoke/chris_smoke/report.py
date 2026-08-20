"""
Presentation: human-readable step lines while running, one machine-readable
JSON verdict line last (CI parses that; everything else is for people).
"""

from __future__ import annotations

import json
from dataclasses import dataclass

from .client import CallRecord
from .scenario import StepResult


@dataclass
class Reporter:
    """Streams progress to stdout as the scenario runs."""
    verbose: bool = False

    def step(self, result: StepResult) -> None:
        mark = "✓" if result.ok else "✗"
        print(f"  {mark} {result.name} ({result.seconds:.1f}s)")
        if result.detail:
            print(f"      {result.detail}")

    def progress(self, message: str) -> None:
        print(f"      · {message}")

    def info(self, message: str) -> None:
        print(message)

    def call(self, record: CallRecord) -> None:
        """--verbose HTTP-trace line, emitted by the client as calls happen."""
        status = "ok" if record.ok else f"ERR {record.error}"
        print(f"        [{record.call}] {record.target} "
              f"({record.seconds * 1000:.0f} ms) {status}")


def json_verdict(*, passed: bool, exit_code: int, failed_step: str | None,
                 steps: list[StepResult], duration_s: float,
                 artifacts_dir: str | None) -> str:
    return json.dumps({
        "verdict": "pass" if passed else "fail",
        "exit_code": exit_code,
        "failed_step": failed_step,
        "duration_s": round(duration_s, 1),
        "steps": [{"name": s.name, "ok": s.ok, "seconds": round(s.seconds, 2)}
                  for s in steps],
        "artifacts": artifacts_dir,
    })
