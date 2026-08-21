"""
The documented artifact layout, and the guarantee that diagnostics collection
never masks the test's own verdict.
"""

from __future__ import annotations

import dataclasses
import json
import shutil
from pathlib import Path

from chris_smoke import diagnostics, scenario


def journey_state(fake_cube, cfg, reporter):
    state = scenario.new_state(cfg.username)
    scenario.run_steps(scenario.PREFLIGHT, fake_cube, cfg, state, reporter,
                       reporter.step)
    scenario.run_steps(scenario.JOURNEY, fake_cube, cfg, state, reporter,
                       reporter.step)
    return state


def test_documented_artifact_layout(fake_cube, cfg, reporter):
    state = journey_state(fake_cube, cfg, reporter)
    out_dir = diagnostics.collect(cfg, fake_cube, state, "some step")

    assert out_dir is not None and out_dir.parent == cfg.artifacts_dir
    names = {p.name for p in out_dir.iterdir()}
    assert {"trace.jsonl", "state.json", "instances.json"} <= names
    assert "oc" not in names  # no kubeconfig configured
    assert "collection-errors.txt" not in names

    state_doc = json.loads((out_dir / "state.json").read_text())
    assert state_doc["failed_step"] == "some step"
    assert state_doc["payload"]["sha256"] == state.payload.sha256
    assert state_doc["downloaded_sha256"] == state.payload.sha256
    assert json.loads((out_dir / "instances.json").read_text())


def test_unwritable_artifacts_dir_returns_none(fake_cube, cfg, reporter,
                                               tmp_path):
    blocker = tmp_path / "blocker"
    blocker.write_text("a file where a directory must go")
    broken_cfg = dataclasses.replace(cfg, artifacts_dir=blocker / "nested")
    state = journey_state(fake_cube, cfg, reporter)
    assert diagnostics.collect(broken_cfg, fake_cube, state, "x") is None


def test_oc_skipped_when_binary_missing(fake_cube, cfg, reporter, monkeypatch):
    kube_cfg = dataclasses.replace(cfg, kubeconfig="/some/kubeconfig")
    monkeypatch.setattr(shutil, "which", lambda name: None)
    state = journey_state(fake_cube, cfg, reporter)
    out_dir = diagnostics.collect(kube_cfg, fake_cube, state, "x")
    assert "oc" not in {p.name for p in out_dir.iterdir()}


def test_failing_collector_is_recorded_not_raised(fake_cube, cfg, reporter,
                                                  monkeypatch):
    state = journey_state(fake_cube, cfg, reporter)

    def explode(client):
        raise OSError("simulated trace failure")

    monkeypatch.setattr(diagnostics, "_trace_jsonl", explode)
    out_dir = diagnostics.collect(cfg, fake_cube, state, "x")
    errors = (out_dir / "collection-errors.txt").read_text()
    assert "trace.jsonl" in errors and "simulated trace failure" in errors
    assert "state.json" in {p.name for p in out_dir.iterdir()}  # others intact


def test_unwritable_oc_dir_never_masks_the_verdict(fake_cube, cfg, reporter,
                                                   monkeypatch):
    # the oc/ mkdir failing (volume turned read-only mid-run) must degrade to
    # a collection error, never an exception that re-verdicts the run
    kube_cfg = dataclasses.replace(cfg, kubeconfig="/some/kubeconfig")
    monkeypatch.setattr(shutil, "which", lambda name: "/usr/bin/oc")
    state = journey_state(fake_cube, cfg, reporter)

    real_mkdir = Path.mkdir

    def flaky_mkdir(self, *args, **kwargs):
        if self.name == "oc":
            raise OSError("read-only file system")
        return real_mkdir(self, *args, **kwargs)

    monkeypatch.setattr(Path, "mkdir", flaky_mkdir)
    out_dir = diagnostics.collect(kube_cfg, fake_cube, state, "x")
    assert out_dir is not None
    assert "read-only" in (out_dir / "collection-errors.txt").read_text()


def test_every_write_failing_never_raises(fake_cube, cfg, reporter, monkeypatch):
    # disk full right after the run dir is created: even collection-errors.txt
    # is unwritable, and collect() must still return quietly
    state = journey_state(fake_cube, cfg, reporter)

    def refuse(self, *args, **kwargs):
        raise OSError("disk full")

    monkeypatch.setattr(Path, "write_text", refuse)
    out_dir = diagnostics.collect(cfg, fake_cube, state, "x")
    assert out_dir is not None and list(out_dir.iterdir()) == []
