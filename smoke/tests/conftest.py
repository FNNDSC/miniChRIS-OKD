"""
A scripted in-memory CUBE standing in for the adapter — the scenario and
poller are exercised against the adapter's *interface*, never the network.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from pathlib import Path

import pytest

from chris_smoke.client import CubeError
from chris_smoke.config import SmokeConfig


@dataclass
class FakeCube:
    """Mimics CubeClient's public surface with scriptable behavior."""

    # instance id → successive statuses returned by get_instance (last repeats)
    status_script: dict[int, list[str]] = field(default_factory=dict)
    plugins: dict[str, dict] = field(default_factory=lambda: {
        "pl-dircopy": {"id": 3, "name": "pl-dircopy", "version": "3.0.0"},
        "pl-simpledsapp": {"id": 4, "name": "pl-simpledsapp", "version": "2.1.5"},
    })
    corrupt_output: bool = False
    fail_delete_userfile: bool = False
    events: list = field(default_factory=list)
    on_event: object = None

    connected: bool = False
    uploaded: dict[str, bytes] = field(default_factory=dict)
    instances: dict[int, dict] = field(default_factory=dict)
    deleted_feeds: list[int] = field(default_factory=list)
    deleted_files: list[int] = field(default_factory=list)
    deleted_folders: list[str] = field(default_factory=list)
    _next_id: int = 0

    # -- lifecycle

    def probe(self) -> int:
        return 401

    def connect(self) -> None:
        self.connected = True

    # -- journey

    def find_plugin(self, name: str) -> dict | None:
        return self.plugins.get(name)

    def upload(self, upload_path: str, content: bytes) -> dict:
        self.uploaded[upload_path] = content
        return {"id": 100, "fname": upload_path, "fsize": len(content)}

    def create_instance(self, plugin_id: int, params: dict) -> dict:
        self._next_id += 1
        instance_id = self._next_id
        name = next(p["name"] for p in self.plugins.values()
                    if p["id"] == plugin_id)
        instance = {"id": instance_id, "feed_id": 7, "plugin_name": name,
                    "status": "created",
                    "output_path": f"home/smoke/feeds/feed_7/{name}_{instance_id}/data"}
        self.instances[instance_id] = instance
        self.status_script.setdefault(instance_id, ["finishedSuccessfully"])
        return dict(instance)

    def get_instance(self, instance_id: int) -> dict:
        script = self.status_script[instance_id]
        status = script.pop(0) if len(script) > 1 else script[0]
        instance = dict(self.instances[instance_id], status=status)
        self.instances[instance_id]["status"] = status
        return instance

    def list_files(self, path_prefix: str) -> list[dict]:
        content = next(iter(self.uploaded.values()), b"")
        return [{"id": 200, "fname": f"{path_prefix}/input.txt",
                 "fsize": len(content), "file_resource": "fake://download/200"}]

    def download(self, file_resource_url: str) -> bytes:
        content = next(iter(self.uploaded.values()), b"")
        return b"corrupted" if self.corrupt_output else content

    # -- cleanup

    def delete_feed(self, feed_id: int) -> None:
        self.deleted_feeds.append(feed_id)

    def delete_userfile(self, file_id: int) -> None:
        if self.fail_delete_userfile:
            raise CubeError(f"simulated delete failure for file {file_id}")
        self.deleted_files.append(file_id)

    def delete_folder(self, path: str) -> None:
        self.deleted_folders.append(path)


class NullReporter:
    def __init__(self):
        self.progress_lines: list[str] = []
        self.steps: list = []

    def progress(self, message: str) -> None:
        self.progress_lines.append(message)

    def step(self, result) -> None:
        self.steps.append(result)


@pytest.fixture
def fake_cube() -> FakeCube:
    return FakeCube()


@pytest.fixture
def reporter() -> NullReporter:
    return NullReporter()


@pytest.fixture
def cfg(tmp_path: Path) -> SmokeConfig:
    return SmokeConfig(
        cube_url="https://cube.example/api/v1/", username="smoke",
        password="pw", verify=True, timeout_s=5.0, poll_interval_s=0.0,
        request_timeout_s=5.0, artifacts_dir=tmp_path / "artifacts",
        keep=False, kubeconfig=None, namespace="chris", verbose=False)
