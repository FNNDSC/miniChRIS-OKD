"""
Thin adapter over ``python-chrisclient`` — the ONLY module that speaks HTTP or
imports the client library (the seam; swap or patch here on API drift, exactly
like ``benchmarks/chris_api.py`` in the CUBE repo).

python-chrisclient covers auth, upload, plugin/instance calls. Three gaps are
absorbed with direct ``requests`` calls against CUBE's JSON rendering
(``Accept: application/json`` inlines hyperlink fields like ``file_resource``
that the library's Collection+JSON parsing drops):

* listing files under a path — ``userfiles/search/?fname=<prefix>`` is a
  *startswith* filter whose queryset spans the whole ``home/`` tree, so it
  reaches plugin *output* files as well as uploads (CUBE 6 removed
  ``plugins/instances/<n>/files/``);
* downloading file content (the library returns descriptors only);
* deleting feeds/folders (no library method).

TLS: the library calls module-level ``requests`` functions with no ``verify``
passthrough, so the effective verify value (CA bundle path or False) is pinned
process-wide via ``requests.Session.merge_environment_settings`` — acceptable
in this single-purpose CLI process, and it keeps every request consistent.

Every adapter call is timed and appended to :attr:`CubeClient.events`, the
HTTP trace that failure diagnostics persist.
"""

from __future__ import annotations

import io
import time
from dataclasses import dataclass
from typing import Any, Callable

import requests
import urllib3
from chrisclient.client import Client
from chrisclient.exceptions import ChrisRequestException


class CubeError(Exception):
    """A CUBE API call failed; the message carries the call context."""


@dataclass
class CallRecord:
    call: str
    target: str
    ok: bool
    seconds: float
    error: str | None = None


_TLS_VERIFY: bool | str | None = None  # None = not pinned yet


def _pin_process_tls(verify: bool | str) -> None:
    global _TLS_VERIFY
    if _TLS_VERIFY is None:
        original = requests.Session.merge_environment_settings

        # Parameter names must match the original exactly — a keyword call
        # (verify=..., cert=...) would TypeError against renamed parameters.
        def merged(self, url, proxies, stream, verify, cert):  # noqa: ANN001
            settings = original(self, url, proxies, stream, verify, cert)
            if _TLS_VERIFY is not None:
                settings["verify"] = _TLS_VERIFY
            return settings

        requests.Session.merge_environment_settings = merged  # type: ignore[method-assign]
    _TLS_VERIFY = verify
    if verify is False:
        urllib3.disable_warnings(urllib3.exceptions.InsecureRequestWarning)


class CubeClient:
    """One authenticated conversation with a CUBE instance."""

    def __init__(self, url: str, username: str, password: str, *,
                 verify: bool | str = True, request_timeout_s: float = 30.0):
        self.url = url if url.endswith("/") else url + "/"
        self._username = username
        self._password = password
        self._timeout = request_timeout_s
        self.events: list[CallRecord] = []
        self.on_event: Callable[[CallRecord], None] | None = None
        _pin_process_tls(verify)
        self._session = requests.Session()
        self._session.verify = verify
        self._api: Client | None = None

    # -- lifecycle -------------------------------------------------------------

    def probe(self) -> int:
        """GET the API root unauthenticated. Any HTTP status (401 included)
        proves DNS + Route + server; transport errors raise :class:`CubeError`."""
        def go() -> int:
            resp = self._session.get(self.url, timeout=self._timeout,
                                     headers={"Accept": "application/json"})
            return resp.status_code
        return self._record("probe", self.url, go)

    def connect(self) -> None:
        """Obtain a DRF token and bind the library client to it."""
        def go() -> None:
            try:
                token = Client.get_auth_token(self.url + "auth-token/",
                                              self._username, self._password)
            except KeyError as exc:  # library raises bare KeyError on a 400
                raise CubeError("no token in auth response — wrong credentials, "
                                "or the auth endpoint is broken") from exc
            api = Client(self.url, token=token)
            api.set_urls()
            self._session.headers["Authorization"] = f"Token {token}"
            self._api = api
        self._record("auth", self.url + "auth-token/", go)

    # -- journey calls ---------------------------------------------------------

    def find_plugin(self, name: str) -> dict | None:
        def go() -> dict | None:
            matches = self._client.get_plugins({"name_exact": name})["data"]
            return matches[0] if matches else None
        return self._record("find_plugin", name, go)

    def upload(self, upload_path: str, content: bytes) -> dict:
        def go() -> dict:
            return self._client.upload_file(upload_path, io.BytesIO(content))
        return self._record("upload", upload_path, go)

    def create_instance(self, plugin_id: int, params: dict) -> dict:
        def go() -> dict:
            return self._client.create_plugin_instance(plugin_id, params)
        return self._record("create_instance", f"plugin/{plugin_id}", go)

    def get_instance(self, instance_id: int) -> dict:
        def go() -> dict:
            return self._client.get_plugin_instance_by_id(instance_id)
        return self._record("get_instance", str(instance_id), go)

    def list_files(self, path_prefix: str) -> list[dict]:
        """All files at-or-under a ChRIS path, with links (``file_resource``,
        ``id``, ``fname``, ``fsize``) inline."""
        def go() -> list[dict]:
            files: list[dict] = []
            url: str | None = self.url + "userfiles/search/"
            params: dict[str, Any] | None = {"fname": path_prefix, "limit": 100}
            while url:
                payload = self._raw_json("GET", url, params=params)
                files.extend(payload.get("results", []))
                url, params = payload.get("next"), None
            return files
        return self._record("list_files", path_prefix, go)

    def download(self, file_resource_url: str) -> bytes:
        def go() -> bytes:
            resp = self._session.get(file_resource_url, timeout=self._timeout)
            self._check(resp)
            return resp.content
        return self._record("download", file_resource_url, go)

    # -- cleanup calls ---------------------------------------------------------

    def delete_feed(self, feed_id: int) -> None:
        def go() -> None:
            self._check(self._session.delete(f"{self.url}{feed_id}/",
                                             timeout=self._timeout))
        self._record("delete_feed", str(feed_id), go)

    def delete_userfile(self, file_id: int) -> None:
        def go() -> None:
            self._client.delete_user_file(file_id)
        self._record("delete_userfile", str(file_id), go)

    def delete_folder(self, path: str) -> None:
        def go() -> None:
            folders = self._client.get_file_browser_folders({"path": path})["data"]
            if folders:
                self._check(self._session.delete(
                    f"{self.url}filebrowser/{folders[0]['id']}/",
                    timeout=self._timeout))
        self._record("delete_folder", path, go)

    # -- internals -------------------------------------------------------------

    @property
    def _client(self) -> Client:
        if self._api is None:
            raise CubeError("not authenticated — connect() must run first")
        return self._api

    def _record(self, call: str, target: str, fn: Callable[[], Any]) -> Any:
        start = time.perf_counter()
        try:
            result = fn()
        # Deliberately broad: the adapter's contract is that *any* failure
        # underneath it (transport, library, or unexpected payload shape —
        # e.g. bare KeyErrors out of python-chrisclient) surfaces as a
        # CubeError carrying the call context, never as a crash.
        except Exception as exc:  # noqa: BLE001
            detail = f"{type(exc).__name__}: {exc}" if not isinstance(
                exc, (CubeError, ChrisRequestException)) else str(exc)
            record = CallRecord(call, target, False,
                                time.perf_counter() - start, detail)
            self._emit(record)
            raise CubeError(f"{call} {target}: {detail}") from exc
        self._emit(CallRecord(call, target, True, time.perf_counter() - start))
        return result

    def _emit(self, record: CallRecord) -> None:
        self.events.append(record)
        if self.on_event is not None:
            self.on_event(record)

    def _raw_json(self, method: str, url: str, *,
                  params: dict | None = None) -> dict:
        resp = self._session.request(method, url, params=params,
                                     timeout=self._timeout,
                                     headers={"Accept": "application/json"})
        self._check(resp)
        return resp.json()

    @staticmethod
    def _check(resp: requests.Response) -> None:
        if not 200 <= resp.status_code < 300:
            raise CubeError(f"HTTP {resp.status_code} {resp.request.method} "
                            f"{resp.url}: {resp.text[:300]}")
