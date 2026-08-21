"""
The adapter seam itself: error wrapping, pagination, TLS pinning, and a
conformance check binding FakeCube to CubeClient's real surface (so the
two sides of the seam cannot drift silently).
"""

from __future__ import annotations

import inspect
from types import SimpleNamespace

import pytest
import requests

from chris_smoke import client as client_module
from chris_smoke.client import CubeClient, CubeError


def make_client() -> CubeClient:
    return CubeClient("https://cube.example/api/v1", "user", "pw", verify=False)


def test_url_gets_trailing_slash():
    assert make_client().url.endswith("/api/v1/")


def test_record_wraps_unexpected_exceptions_and_traces():
    cube = make_client()

    def boom():
        raise ValueError("boom")

    with pytest.raises(CubeError, match="ValueError: boom"):
        cube._record("call-name", "target", boom)
    record = cube.events[-1]
    assert not record.ok and record.call == "call-name"
    assert "ValueError: boom" in record.error


def test_methods_require_connect_first():
    with pytest.raises(CubeError, match="not authenticated"):
        make_client().find_plugin("pl-dircopy")


def test_connect_translates_bad_credentials_keyerror(monkeypatch):
    # python-chrisclient raises a bare KeyError('token') on a rejected login
    def fake_get_auth_token(url, username, password, timeout=30):
        raise KeyError("token")

    monkeypatch.setattr(client_module.Client, "get_auth_token",
                        staticmethod(fake_get_auth_token))
    with pytest.raises(CubeError, match="no token in auth response"):
        make_client().connect()


def test_list_files_follows_pagination(monkeypatch):
    cube = make_client()
    pages = {
        cube.url + "userfiles/search/": {
            "results": [{"id": 1}, {"id": 2}], "next": "https://x/page2"},
        "https://x/page2": {"results": [{"id": 3}], "next": None},
    }
    calls: list[tuple[str, dict | None]] = []

    def fake_raw_json(method, url, *, params=None):
        calls.append((url, params))
        return pages[url]

    monkeypatch.setattr(cube, "_raw_json", fake_raw_json)
    files = cube.list_files("home/smoke/some/path")
    assert [f["id"] for f in files] == [1, 2, 3]
    assert calls[0][1] == {"fname": "home/smoke/some/path", "limit": 100}
    assert calls[1][1] is None  # 'next' URLs already carry the query


def test_check_raises_on_non_2xx():
    response = SimpleNamespace(status_code=404, url="https://x/y",
                               request=SimpleNamespace(method="GET"),
                               text="not found")
    with pytest.raises(CubeError, match="HTTP 404 GET"):
        CubeClient._check(response)
    CubeClient._check(SimpleNamespace(status_code=202, url="", request=None,
                                      text=""))  # async deletes are fine


def test_tls_pin_is_idempotent_updatable_and_keyword_safe():
    client_module._pin_process_tls(False)
    wrapped = requests.Session.merge_environment_settings
    client_module._pin_process_tls("/some/ca.crt")
    # re-pinning updates the value without stacking another wrapper
    assert requests.Session.merge_environment_settings is wrapped

    session = requests.Session()
    # keyword invocation must work: parameter names must match the original
    settings = session.merge_environment_settings(
        url="https://x", proxies={}, stream=False, verify=True, cert=None)
    assert settings["verify"] == "/some/ca.crt"


def test_default_verify_true_is_not_pinned(monkeypatch):
    # verify=True must leave requests' own resolution (REQUESTS_CA_BUNDLE
    # included) in effect rather than overriding it process-wide
    monkeypatch.delenv("REQUESTS_CA_BUNDLE", raising=False)
    monkeypatch.delenv("CURL_CA_BUNDLE", raising=False)
    client_module._pin_process_tls(True)
    settings = requests.Session().merge_environment_settings(
        url="https://x", proxies={}, stream=False, verify=True, cert=None)
    assert settings["verify"] is True


def test_fake_cube_conforms_to_real_adapter_surface(fake_cube):
    """Bind the seam's two sides: every public CubeClient method must exist on
    FakeCube with identical parameter names, so scenario tests exercise the
    surface the real adapter actually has."""
    real_methods = {
        name: fn for name, fn in inspect.getmembers(CubeClient, inspect.isfunction)
        if not name.startswith("_")
    }
    assert real_methods, "no public methods found on CubeClient?"
    for name, fn in real_methods.items():
        fake_fn = getattr(type(fake_cube), name, None)
        assert fake_fn is not None, f"FakeCube is missing {name}()"
        real_params = [p for p in inspect.signature(fn).parameters if p != "self"]
        fake_params = [p for p in inspect.signature(fake_fn).parameters
                       if p != "self"]
        assert fake_params == real_params, f"signature drift on {name}()"
    assert hasattr(fake_cube, "events") and hasattr(fake_cube, "on_event")
