"""
Failure diagnostics: persist enough to distinguish routing, auth, storage, and
execution problems without re-running the test.

Written under ``<artifacts_dir>/<UTC timestamp>/``:

* ``trace.jsonl``     — every adapter API call (timing, target, error)
* ``state.json``      — ids, paths, statuses, checksums the journey accumulated
* ``instances.json``  — fresh plugin-instance details (status, error fields)
* ``oc/*.txt``        — pods/events/jobs + per-deployment logs, when ``oc`` and
  a kubeconfig are available (harness host); skipped silently otherwise

Collection is strictly best-effort: a diagnostics problem must never mask the
test's own verdict, so every sub-collector failure is recorded in
``collection-errors.txt`` instead of raised.
"""

from __future__ import annotations

import dataclasses
import json
import shutil
import subprocess
import time
from pathlib import Path

from .client import CubeClient
from .config import SmokeConfig
from .scenario import RunState
from .verify import sha256_hex

_OC_TIMEOUT_S = 30

_OC_SNAPSHOTS = {
    "pods.txt": ["get", "pods", "-o", "wide"],
    "events.txt": ["get", "events", "--sort-by=.lastTimestamp"],
    "jobs.txt": ["get", "jobs"],
    "pvc.txt": ["get", "pvc"],
}


def collect(cfg: SmokeConfig, client: CubeClient, state: RunState,
            failed_step: str | None) -> Path | None:
    try:
        out_dir = cfg.artifacts_dir / time.strftime("%Y%m%d-%H%M%SZ", time.gmtime())
        out_dir.mkdir(parents=True, exist_ok=True)
    except OSError:
        return None

    errors: list[str] = []
    for name, collector in (
        ("trace.jsonl", lambda: _trace_jsonl(client)),
        ("state.json", lambda: _state_json(state, failed_step)),
        ("instances.json", lambda: _instances_json(client, state)),
    ):
        try:
            (out_dir / name).write_text(collector())
        except Exception as exc:  # noqa: BLE001 — never mask the test verdict
            errors.append(f"{name}: {exc}")

    errors.extend(_collect_oc(cfg, out_dir))

    if errors:
        (out_dir / "collection-errors.txt").write_text("\n".join(errors) + "\n")
    return out_dir


def _trace_jsonl(client: CubeClient) -> str:
    return "\n".join(json.dumps(dataclasses.asdict(r)) for r in client.events) + "\n"


def _state_json(state: RunState, failed_step: str | None) -> str:
    return json.dumps({
        "failed_step": failed_step,
        "payload": {"name": state.payload.name, "bytes": len(state.payload.content),
                    "sha256": state.payload.sha256},
        "upload_path": state.upload_path,
        "upload_id": state.upload_id,
        "feed_id": state.feed_id,
        "instance_statuses": state.statuses,
        "output_path": state.output_path,
        "output_files": [{k: f.get(k) for k in ("id", "fname", "fsize")}
                         for f in state.output_files],
        "downloaded_sha256": (None if state.downloaded is None
                              else sha256_hex(state.downloaded)),
    }, indent=2)


def _instances_json(client: CubeClient, state: RunState) -> str:
    details = []
    for instance_id in state.instance_ids():
        try:
            details.append(client.get_instance(instance_id))
        except Exception as exc:  # noqa: BLE001
            details.append({"id": instance_id, "fetch_error": str(exc)})
    return json.dumps(details, indent=2, default=str)


def _collect_oc(cfg: SmokeConfig, out_dir: Path) -> list[str]:
    if not cfg.kubeconfig or shutil.which("oc") is None:
        return []

    oc_dir = out_dir / "oc"
    oc_dir.mkdir(exist_ok=True)
    errors = []

    for name, args in _OC_SNAPSHOTS.items():
        error = _oc_to_file(cfg, args, oc_dir / name)
        if error:
            errors.append(f"oc/{name}: {error}")

    deployments, error = _oc_capture(cfg, ["get", "deploy", "-o", "name"])
    if error:
        errors.append(f"oc deployment discovery: {error}")
        return errors
    for deploy in deployments.split():
        log_name = f"logs-{deploy.split('/')[-1]}.txt"
        error = _oc_to_file(cfg, ["logs", deploy, "--all-containers", "--tail=200"],
                            oc_dir / log_name)
        if error:
            errors.append(f"oc/{log_name}: {error}")
    return errors


def _oc_capture(cfg: SmokeConfig, args: list[str]) -> tuple[str, str | None]:
    command = ["oc", "--kubeconfig", cfg.kubeconfig, "-n", cfg.namespace, *args]
    try:
        proc = subprocess.run(command, capture_output=True, text=True,
                              timeout=_OC_TIMEOUT_S)
    except (OSError, subprocess.TimeoutExpired) as exc:
        return "", str(exc)
    if proc.returncode != 0:
        return proc.stdout, proc.stderr.strip() or f"exit {proc.returncode}"
    return proc.stdout, None


def _oc_to_file(cfg: SmokeConfig, args: list[str], path: Path) -> str | None:
    output, error = _oc_capture(cfg, args)
    if output:
        path.write_text(output)
    return error
