"""
The CI contract: exit-code mapping and the always-present JSON verdict line.
CubeClient is monkeypatched with the FakeCube, so main() runs end to end
without a network.
"""

from __future__ import annotations

import json

import pytest

from chris_smoke import cli


@pytest.fixture(autouse=True)
def clean_env(monkeypatch):
    for key in ("CUBE_URL", "CHRIS_SMOKE_USER", "CHRIS_SMOKE_PASSWORD",
                "CHRIS_SMOKE_PASSWORD_FILE", "SMOKE_TIMEOUT", "SMOKE_CA_BUNDLE",
                "SMOKE_INSECURE", "SMOKE_POLL_INTERVAL", "SMOKE_ARTIFACTS_DIR",
                "SMOKE_KUBECONFIG", "SMOKE_NAMESPACE", "SMOKE_REQUEST_TIMEOUT"):
        monkeypatch.delenv(key, raising=False)


def run_main(monkeypatch, fake_cube, tmp_path, extra_args=()):
    monkeypatch.setattr(cli, "CubeClient", lambda *args, **kwargs: fake_cube)
    return cli.main(["--url", "https://cube.example/api/v1/",
                     "--user", "smoke", "--password", "pw", "--insecure",
                     "--artifacts-dir", str(tmp_path / "artifacts"),
                     "--poll-interval", "0.01", *extra_args])


def last_json_line(capsys) -> dict:
    lines = capsys.readouterr().out.strip().splitlines()
    return json.loads(lines[-1])


def test_pass_exits_0_with_verdict(monkeypatch, fake_cube, tmp_path, capsys):
    assert run_main(monkeypatch, fake_cube, tmp_path) == 0
    verdict = last_json_line(capsys)
    assert verdict["verdict"] == "pass" and verdict["exit_code"] == 0
    assert verdict["failed_step"] is None and verdict["artifacts"] is None
    assert fake_cube.deleted_feeds == [7]


def test_journey_failure_exits_1_with_diagnostics(monkeypatch, fake_cube,
                                                  tmp_path, capsys):
    fake_cube.corrupt_output = True
    assert run_main(monkeypatch, fake_cube, tmp_path) == 1
    verdict = last_json_line(capsys)
    assert verdict["verdict"] == "fail" and verdict["exit_code"] == 1
    assert verdict["failed_step"] == "verify output checksum"
    artifacts = tmp_path / "artifacts"
    run_dir = next(artifacts.iterdir())
    assert {(p.name) for p in run_dir.iterdir()} >= {"trace.jsonl", "state.json",
                                                     "instances.json"}
    assert fake_cube.deleted_feeds == []  # feed kept as evidence


def test_preflight_failure_exits_2(monkeypatch, fake_cube, tmp_path, capsys):
    del fake_cube.plugins["pl-simpledsapp"]
    assert run_main(monkeypatch, fake_cube, tmp_path) == 2
    verdict = last_json_line(capsys)
    assert verdict["exit_code"] == 2
    assert verdict["failed_step"] == "smoke plugins registered"


def test_bad_flag_exits_2_with_verdict(capsys):
    assert cli.main(["--bogus"]) == 2
    verdict = last_json_line(capsys)
    assert verdict["exit_code"] == 2
    assert verdict["failed_step"] == "configuration"


def test_bad_flag_value_exits_2_with_verdict(capsys):
    assert cli.main(["--timeout", "abc"]) == 2
    assert last_json_line(capsys)["failed_step"] == "configuration"


def test_internal_error_still_exits_1_with_verdict(monkeypatch, capsys):
    # whatever explodes outside a step (here: the client constructor), the
    # process must still end with a verdict line and the contract exit code
    def explode(*args, **kwargs):
        raise RuntimeError("client constructor blew up")

    monkeypatch.setattr(cli, "CubeClient", explode)
    assert cli.main(["--url", "https://cube.example/api/v1/", "--user", "smoke",
                     "--password", "pw", "--insecure"]) == 1
    verdict = last_json_line(capsys)
    assert verdict["exit_code"] == 1
    assert verdict["failed_step"] == "internal error"


def test_keep_skips_cleanup(monkeypatch, fake_cube, tmp_path, capsys):
    assert run_main(monkeypatch, fake_cube, tmp_path, ["--keep"]) == 0
    assert fake_cube.deleted_feeds == []
    assert "--keep: leaving feed" in capsys.readouterr().out


def test_partial_cleanup_failure_reports_honestly(monkeypatch, fake_cube,
                                                  tmp_path, capsys):
    # feed delete succeeds, userfile delete fails: exit 1, but the output must
    # not claim the (already deleted) feed was kept
    fake_cube.fail_delete_userfile = True
    assert run_main(monkeypatch, fake_cube, tmp_path) == 1
    out = capsys.readouterr().out
    assert fake_cube.deleted_feeds == [7]
    assert "kept for debugging" not in out


def test_unexpected_step_exception_still_yields_verdict(monkeypatch, fake_cube,
                                                        tmp_path, capsys):
    # simulate payload-shape drift: upload response missing "id" → KeyError
    # inside a step must become a failed step, not an uncaught traceback
    monkeypatch.setattr(type(fake_cube), "upload",
                        lambda self, path, content: {"fname": path})
    assert run_main(monkeypatch, fake_cube, tmp_path) == 1
    out = capsys.readouterr().out
    verdict = json.loads(out.strip().splitlines()[-1])
    assert verdict["failed_step"] == "upload test file"
    assert "unexpected KeyError" in out
