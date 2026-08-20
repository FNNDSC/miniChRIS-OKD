import pytest

from chris_smoke.config import ConfigError, load_config

BASE_ENV = {
    "CUBE_URL": "https://cube.example/api/v1",
    "CHRIS_SMOKE_USER": "smoke",
    "CHRIS_SMOKE_PASSWORD": "pw",
}


def set_env(monkeypatch, extra=None):
    for key in ("CUBE_URL", "CHRIS_SMOKE_USER", "CHRIS_SMOKE_PASSWORD",
                "CHRIS_SMOKE_PASSWORD_FILE", "SMOKE_TIMEOUT", "SMOKE_CA_BUNDLE",
                "SMOKE_INSECURE", "SMOKE_POLL_INTERVAL", "SMOKE_ARTIFACTS_DIR",
                "SMOKE_KUBECONFIG", "SMOKE_NAMESPACE", "SMOKE_REQUEST_TIMEOUT"):
        monkeypatch.delenv(key, raising=False)
    for key, value in {**BASE_ENV, **(extra or {})}.items():
        monkeypatch.setenv(key, value)


def test_env_only_with_defaults(monkeypatch):
    set_env(monkeypatch)
    cfg = load_config([])
    assert cfg.cube_url == "https://cube.example/api/v1/"  # slash appended
    assert cfg.username == "smoke" and cfg.password == "pw"
    assert cfg.verify is True
    assert cfg.timeout_s == 600.0 and cfg.poll_interval_s == 5.0
    assert not cfg.keep and cfg.kubeconfig is None


def test_flags_override_env(monkeypatch):
    set_env(monkeypatch, {"SMOKE_TIMEOUT": "60"})
    cfg = load_config(["--timeout", "30", "--keep", "--user", "other"])
    assert cfg.timeout_s == 30.0 and cfg.keep and cfg.username == "other"


def test_password_file(monkeypatch, tmp_path):
    secret = tmp_path / "pw"
    secret.write_text("s3cret\n")
    set_env(monkeypatch, {"CHRIS_SMOKE_PASSWORD": "",
                          "CHRIS_SMOKE_PASSWORD_FILE": str(secret)})
    assert load_config([]).password == "s3cret"


def test_missing_url_is_config_error(monkeypatch):
    set_env(monkeypatch, {"CUBE_URL": ""})
    with pytest.raises(ConfigError, match="CUBE URL"):
        load_config([])


def test_insecure_and_ca_bundle(monkeypatch, tmp_path):
    set_env(monkeypatch)
    assert load_config(["--insecure"]).verify is False

    bundle = tmp_path / "ca.crt"
    bundle.write_text("cert")
    assert load_config(["--ca-bundle", str(bundle)]).verify == str(bundle)

    with pytest.raises(ConfigError, match="CA bundle"):
        load_config(["--ca-bundle", str(tmp_path / "missing.crt")])

    monkeypatch.setenv("SMOKE_INSECURE", "1")
    assert load_config([]).verify is False


def test_non_numeric_timeout_is_config_error(monkeypatch):
    set_env(monkeypatch, {"SMOKE_TIMEOUT": "soon"})
    with pytest.raises(ConfigError, match="not a number"):
        load_config([])
