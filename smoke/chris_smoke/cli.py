"""
CLI orchestration and the exit-code contract CI depends on:

* ``0`` — the full journey passed (and cleanup succeeded, unless ``--keep``);
* ``1`` — a journey step failed: ChRIS is deployed but functionally broken;
* ``2`` — configuration or preflight failure: the invocation or deployment
  setup is wrong, the product was not actually exercised.

On any failure, diagnostics are collected and their location printed. The last
stdout line is always a single-line JSON verdict for machine consumption.
"""

from __future__ import annotations

import time
import traceback

from . import diagnostics, report, scenario
from .client import CubeClient
from .config import ConfigError, SmokeConfig, load_config

EXIT_PASS, EXIT_FAIL, EXIT_CONFIG = 0, 1, 2


def main(argv: list[str] | None = None) -> int:
    try:
        cfg = load_config(argv)
    except ConfigError as exc:
        print(f"configuration error: {exc}")
        print(report.json_verdict(passed=False, exit_code=EXIT_CONFIG,
                                  failed_step="configuration", steps=[],
                                  duration_s=0.0, artifacts_dir=None))
        return EXIT_CONFIG
    try:
        return _run(cfg)
    except Exception as exc:  # noqa: BLE001 — last resort: whatever happens,
        # the process must end with a verdict line and the contract exit code
        print(f"internal error: {type(exc).__name__}: {exc}")
        traceback.print_exc()
        print(report.json_verdict(passed=False, exit_code=EXIT_FAIL,
                                  failed_step="internal error", steps=[],
                                  duration_s=0.0, artifacts_dir=None))
        return EXIT_FAIL


def _run(cfg: SmokeConfig) -> int:
    reporter = report.Reporter(verbose=cfg.verbose)
    client = CubeClient(cfg.cube_url, cfg.username, cfg.password,
                        verify=cfg.verify, request_timeout_s=cfg.request_timeout_s)
    if cfg.verbose:
        client.on_event = reporter.call
    state = scenario.new_state(cfg.username)
    start = time.perf_counter()
    all_results: list[scenario.StepResult] = []

    reporter.info(f"ChRIS smoke test — {cfg.cube_url} as '{cfg.username}'")
    reporter.info("preflight:")
    ok, results = scenario.run_steps(scenario.PREFLIGHT, client, cfg, state,
                                     reporter, reporter.step)
    all_results += results
    if not ok:
        return _finish(cfg, client, state, reporter, all_results,
                       start, EXIT_CONFIG)

    reporter.info("journey:")
    ok, results = scenario.run_steps(scenario.JOURNEY, client, cfg, state,
                                     reporter, reporter.step)
    all_results += results
    if not ok:
        return _finish(cfg, client, state, reporter, all_results, start, EXIT_FAIL)

    if cfg.keep:
        reporter.info(f"--keep: leaving feed {state.feed_id} and "
                      f"{state.upload_path} in place")
    else:
        ok, results = scenario.run_steps(scenario.CLEANUP, client, cfg, state,
                                         reporter, reporter.step)
        all_results += results
        if not ok:
            return _finish(cfg, client, state, reporter, all_results,
                           start, EXIT_FAIL)

    return _finish(cfg, client, state, reporter, all_results, start, EXIT_PASS)


def _finish(cfg: SmokeConfig, client: CubeClient, state: scenario.RunState,
            reporter: report.Reporter, results: list[scenario.StepResult],
            start: float, exit_code: int) -> int:
    duration = time.perf_counter() - start
    passed = exit_code == EXIT_PASS
    failed_step = next((r.name for r in results if not r.ok), None)
    artifacts: str | None = None

    if passed:
        reporter.info(f"SMOKE PASS ({duration:.0f}s)")
    else:
        artifacts_dir = diagnostics.collect(cfg, client, state, failed_step)
        artifacts = str(artifacts_dir) if artifacts_dir else None
        reporter.info(f"SMOKE FAIL at '{failed_step}' ({duration:.0f}s)")
        if artifacts:
            reporter.info(f"diagnostics: {artifacts}")
        if state.feed_id is not None and not state.feed_deleted:
            reporter.info(f"feed {state.feed_id} kept for debugging")

    print(report.json_verdict(passed=passed, exit_code=exit_code,
                              failed_step=failed_step, steps=results,
                              duration_s=duration, artifacts_dir=artifacts))
    return exit_code
