"""Pin the JSON verdict schema — CI parses these exact keys."""

from __future__ import annotations

import json

from chris_smoke.report import json_verdict
from chris_smoke.scenario import StepResult


def test_verdict_schema_and_single_line():
    line = json_verdict(
        passed=False, exit_code=1, failed_step="wait for completion",
        steps=[StepResult("upload test file", True, 0.123, "detail"),
               StepResult("wait for completion", False, 5.678, "timed out")],
        duration_s=6.789, artifacts_dir="/tmp/artifacts/x")

    assert "\n" not in line
    verdict = json.loads(line)
    assert set(verdict) == {"verdict", "exit_code", "failed_step",
                            "duration_s", "steps", "artifacts"}
    assert verdict["verdict"] == "fail" and verdict["exit_code"] == 1
    assert verdict["failed_step"] == "wait for completion"
    assert verdict["steps"][0] == {"name": "upload test file", "ok": True,
                                   "seconds": 0.12}
    assert verdict["artifacts"] == "/tmp/artifacts/x"


def test_pass_verdict():
    verdict = json.loads(json_verdict(passed=True, exit_code=0,
                                      failed_step=None, steps=[],
                                      duration_s=21.04, artifacts_dir=None))
    assert verdict["verdict"] == "pass"
    assert verdict["failed_step"] is None and verdict["artifacts"] is None
