"""
The smoke-test journey: *what* happens, in order, and what counts as failure.
How to talk to CUBE lives in :mod:`.client`; how the answer is presented lives
in :mod:`.cli`/:mod:`.report`.

Two step lists with different meanings for the CLI's exit code:

* ``PREFLIGHT`` — reachability, auth, seeded plugins. A failure here means the
  invocation or the deployment *setup* is wrong (exit 2), not that ChRIS is
  functionally broken.
* ``JOURNEY``  — upload → fs plugin → chained ds plugin → poll → download →
  checksum. A failure here is a product failure (exit 1).

``CLEANUP`` runs only after a passing journey (and not with ``--keep``): a
failed run's feed and files are evidence, deliberately left in place.
"""

from __future__ import annotations

import secrets
import time
from dataclasses import dataclass, field
from typing import Callable, Protocol

from .client import CubeClient, CubeError
from .poller import poll_instances
from .verify import Payload, compare, make_payload

# Seeded by chris/chrisomatic.yml.tpl (Phase 2); preflight asserts they exist.
FS_PLUGIN = "pl-dircopy"
DS_PLUGIN = "pl-simpledsapp"
# pfcon rejects zero-argument instances and CUBE surfaces that as a silent
# ``cancelled`` (docs/troubleshooting.md) — dummyInt keeps argv non-empty
# without renaming the output file.
DS_PARAMS = {"dummyInt": 1}


class StepFailure(Exception):
    """A step did not achieve its goal; the message is the diagnosis."""


class Reporter(Protocol):
    def progress(self, message: str) -> None: ...


@dataclass
class StepResult:
    name: str
    ok: bool
    seconds: float
    detail: str = ""


@dataclass
class RunState:
    """Everything the journey accumulates; diagnostics serialize this."""
    payload: Payload
    upload_dir: str
    upload_path: str
    upload_id: int | None = None
    fs_instance: dict | None = None
    ds_instance: dict | None = None
    feed_id: int | None = None
    feed_deleted: bool = False
    statuses: dict[int, str] = field(default_factory=dict)
    output_path: str = ""
    output_files: list[dict] = field(default_factory=list)
    output_file: dict | None = None
    downloaded: bytes | None = None
    plugins: dict[str, dict] = field(default_factory=dict)

    def instance_ids(self) -> list[int]:
        return [int(inst["id"]) for inst in (self.fs_instance, self.ds_instance)
                if inst is not None]


def new_state(username: str) -> RunState:
    # Second-granularity time plus a nonce: two runs in the same second
    # (e.g. concurrent CI jobs against one deployment) must never share an
    # upload path.
    stamp = f'{time.strftime("%Y%m%d-%H%M%S", time.gmtime())}-{secrets.token_hex(3)}'
    payload = make_payload(stamp)
    upload_dir = f"home/{username}/uploads/smoke-{stamp}"
    return RunState(payload=payload, upload_dir=upload_dir,
                    upload_path=f"{upload_dir}/{payload.name}")


# --- preflight steps ---------------------------------------------------------

def step_reachable(client: CubeClient, cfg, state: RunState, reporter: Reporter) -> str:
    try:
        status = client.probe()
    except CubeError as exc:
        hint = ""
        if "SSL" in str(exc) or "certificate" in str(exc):
            hint = " (self-signed Route cert? use --ca-bundle from 'just router-ca', or --insecure)"
        raise StepFailure(f"CUBE unreachable: {exc}{hint}") from exc
    if status >= 500:
        raise StepFailure(f"CUBE responded HTTP {status} — server or Route is broken")
    return f"HTTP {status} from {cfg.cube_url}"


def step_auth(client: CubeClient, cfg, state: RunState, reporter: Reporter) -> str:
    client.connect()
    return f"token obtained for user '{cfg.username}'"


def step_plugins(client: CubeClient, cfg, state: RunState, reporter: Reporter) -> str:
    for name in (FS_PLUGIN, DS_PLUGIN):
        plugin = client.find_plugin(name)
        if plugin is None:
            raise StepFailure(f"plugin {name} not registered (run 'just chris-seed')")
        state.plugins[name] = plugin
    return ", ".join(f"{p['name']} {p['version']}" for p in state.plugins.values())


# --- journey steps -----------------------------------------------------------

def step_upload(client: CubeClient, cfg, state: RunState, reporter: Reporter) -> str:
    uploaded = client.upload(state.upload_path, state.payload.content)
    state.upload_id = int(uploaded["id"])
    size = int(uploaded.get("fsize") or 0)
    if size != len(state.payload.content):
        raise StepFailure(f"uploaded fsize {size} != payload size "
                          f"{len(state.payload.content)}")
    return f"{state.upload_path} ({size} B, sha256 {state.payload.sha256[:12]}…)"


def step_run_fs(client: CubeClient, cfg, state: RunState, reporter: Reporter) -> str:
    instance = client.create_instance(
        int(state.plugins[FS_PLUGIN]["id"]),
        {"dir": state.upload_dir, "title": "smoke: dircopy"})
    state.fs_instance = instance
    state.feed_id = int(instance["feed_id"])
    return f"instance {instance['id']} created (feed {state.feed_id})"


def step_run_ds(client: CubeClient, cfg, state: RunState, reporter: Reporter) -> str:
    assert state.fs_instance is not None
    instance = client.create_instance(
        int(state.plugins[DS_PLUGIN]["id"]),
        {"previous_id": int(state.fs_instance["id"]),
         "title": "smoke: simpledsapp", **DS_PARAMS})
    state.ds_instance = instance
    return f"instance {instance['id']} chained after {state.fs_instance['id']}"


def step_wait(client: CubeClient, cfg, state: RunState, reporter: Reporter) -> str:
    def on_change(instance_id: int, instance: dict) -> None:
        state.statuses[instance_id] = instance.get("status") or ""
        reporter.progress(f"{instance.get('plugin_name', 'instance')} "
                          f"[{instance_id}]: {instance.get('status')}")

    outcome = poll_instances(client, state.instance_ids(),
                             timeout_s=cfg.timeout_s,
                             interval_s=cfg.poll_interval_s,
                             on_change=on_change)
    state.statuses = outcome.statuses
    if not outcome.ok:
        raise StepFailure(outcome.describe())
    return f"all instances finishedSuccessfully in {outcome.seconds:.0f}s"


def step_download(client: CubeClient, cfg, state: RunState, reporter: Reporter) -> str:
    assert state.ds_instance is not None
    ds_id = int(state.ds_instance["id"])
    # Refresh: output_path is only meaningful once the run finished.
    instance = client.get_instance(ds_id)
    state.output_path = instance.get("output_path") or ""
    if not state.output_path:
        raise StepFailure(f"ds instance {ds_id} has no output_path after finishing")

    state.output_files = client.list_files(state.output_path)
    if not state.output_files:
        raise StepFailure(f"no files found under {state.output_path}")

    wanted = f"/{state.payload.name}"
    matches = [f for f in state.output_files if f.get("fname", "").endswith(wanted)]
    if not matches:
        names = ", ".join(f.get("fname", "?") for f in state.output_files)
        raise StepFailure(f"output {state.payload.name} not among: {names}")
    state.output_file = matches[0]
    state.downloaded = client.download(state.output_file["file_resource"])
    return (f"{len(state.output_files)} file(s) under {state.output_path}; "
            f"downloaded {state.output_file['fname']} ({len(state.downloaded)} B)")


def step_verify(client: CubeClient, cfg, state: RunState, reporter: Reporter) -> str:
    assert state.downloaded is not None
    error = compare(state.payload, state.downloaded)
    if error:
        raise StepFailure(error)
    return f"output sha256 matches upload ({state.payload.sha256[:12]}…)"


# --- cleanup -----------------------------------------------------------------

def step_cleanup(client: CubeClient, cfg, state: RunState, reporter: Reporter) -> str:
    assert state.feed_id is not None and state.upload_id is not None
    client.delete_feed(state.feed_id)
    state.feed_deleted = True
    client.delete_userfile(state.upload_id)
    notes = f"deleted feed {state.feed_id} and upload {state.upload_path}"
    try:
        client.delete_folder(state.upload_dir)
    except CubeError as exc:  # empty-folder removal is tidiness, not correctness
        notes += f" (upload folder left behind: {exc})"
    return notes


Step = tuple[str, Callable[[CubeClient, object, RunState, Reporter], str]]

PREFLIGHT: list[Step] = [
    ("CUBE route reachable", step_reachable),
    ("authenticate", step_auth),
    ("smoke plugins registered", step_plugins),
]

JOURNEY: list[Step] = [
    ("upload test file", step_upload),
    (f"run {FS_PLUGIN} (fs)", step_run_fs),
    (f"run {DS_PLUGIN} (ds, chained)", step_run_ds),
    ("wait for completion", step_wait),
    ("download output", step_download),
    ("verify output checksum", step_verify),
]

CLEANUP: list[Step] = [
    ("cleanup (delete feed + upload)", step_cleanup),
]


def run_steps(steps: list[Step], client: CubeClient, cfg, state: RunState,
              reporter, on_step: Callable[[StepResult], None],
              ) -> tuple[bool, list[StepResult]]:
    """Run steps in order, short-circuiting on the first failure."""
    results: list[StepResult] = []
    for name, fn in steps:
        start = time.perf_counter()
        try:
            detail = fn(client, cfg, state, reporter)
            result = StepResult(name, True, time.perf_counter() - start, detail)
        except (StepFailure, CubeError) as exc:
            result = StepResult(name, False, time.perf_counter() - start, str(exc))
        except Exception as exc:  # noqa: BLE001 — e.g. payload-shape drift past
            # the adapter (a KeyError on a missing field) must become a failed
            # step with verdict + diagnostics, never an uncaught traceback
            result = StepResult(name, False, time.perf_counter() - start,
                                f"unexpected {type(exc).__name__}: {exc}")
        results.append(result)
        on_step(result)
        if not result.ok:
            return False, results
    return True, results
