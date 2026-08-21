"""
Runtime configuration: a frozen dataclass assembled from environment variables
and CLI flags (flags win). Everything the other modules need to know about the
outside world — URL, credentials, TLS, timeouts, artifact/diagnostic locations —
comes through here, so the test runs unchanged from the harness host, a LAN
client, or a CI runner.

A :class:`ConfigError` means the *invocation* is wrong, not the product — the
CLI maps it to exit code 2.
"""

from __future__ import annotations

import argparse
import os
from collections.abc import Mapping
from dataclasses import dataclass
from pathlib import Path


class ConfigError(Exception):
    """The invocation is unusable (missing/invalid configuration)."""


class _ArgumentParser(argparse.ArgumentParser):
    """argparse's default error handling calls ``sys.exit(2)`` directly,
    which would skip the CLI's JSON verdict — surface bad flags/values as
    :class:`ConfigError` so they flow through the same exit-2 path as every
    other configuration problem. (``--help`` still exits 0 normally.)"""

    def error(self, message: str):
        raise ConfigError(f"{message} (run with --help for usage)")


@dataclass(frozen=True)
class SmokeConfig:
    cube_url: str                  # CUBE API base, e.g. https://host/api/v1/
    username: str
    password: str
    verify: bool | str             # True = system CAs, path = CA bundle, False = --insecure
    timeout_s: float               # overall budget for plugin-run completion
    poll_interval_s: float
    request_timeout_s: float
    artifacts_dir: Path            # failure diagnostics land under here
    keep: bool                     # keep feed + upload for debugging
    kubeconfig: str | None         # enables `oc` dumps in diagnostics when set
    namespace: str                 # ChRIS namespace for `oc` dumps
    verbose: bool


def build_parser() -> argparse.ArgumentParser:
    parser = _ArgumentParser(
        prog="chris-smoke",
        description="Functional end-to-end smoke test for a ChRIS deployment. "
                    "Exit codes: 0 pass, 1 journey failure, 2 configuration/preflight error.",
    )
    parser.add_argument("--url", default=None,
                        help="CUBE API base URL (env CUBE_URL), e.g. https://host/api/v1/")
    parser.add_argument("--user", default=None,
                        help="ChRIS username (env CHRIS_SMOKE_USER)")
    parser.add_argument("--password", default=None,
                        help="ChRIS password (env CHRIS_SMOKE_PASSWORD or "
                             "CHRIS_SMOKE_PASSWORD_FILE; prefer those over argv)")
    parser.add_argument("--timeout", type=float, default=None, metavar="SECONDS",
                        help="overall plugin-run completion budget (env SMOKE_TIMEOUT, default 600)")
    parser.add_argument("--poll-interval", type=float, default=None, metavar="SECONDS",
                        help="status poll cadence (env SMOKE_POLL_INTERVAL, default 5)")
    parser.add_argument("--artifacts-dir", default=None, metavar="DIR",
                        help="where failure diagnostics are written "
                             "(env SMOKE_ARTIFACTS_DIR, default ./smoke-artifacts)")
    tls = parser.add_mutually_exclusive_group()
    tls.add_argument("--ca-bundle", default=None, metavar="FILE",
                     help="CA bundle for the Route's TLS cert (env SMOKE_CA_BUNDLE); "
                          "extract the harness router CA with 'just router-ca'")
    tls.add_argument("--insecure", action="store_true", default=False,
                     help="skip TLS verification (env SMOKE_INSECURE=1) — dev fallback only")
    parser.add_argument("--keep", action="store_true", default=False,
                        help="keep the feed and uploaded file for debugging (skip cleanup)")
    parser.add_argument("--kubeconfig", default=None,
                        help="kubeconfig for `oc` failure diagnostics (env SMOKE_KUBECONFIG)")
    parser.add_argument("--verbose", "-v", action="store_true", default=False,
                        help="log every API call as it happens")
    return parser


def load_config(argv: list[str] | None = None) -> SmokeConfig:
    args = build_parser().parse_args(argv)
    env = os.environ

    url = args.url or env.get("CUBE_URL") or ""
    if not url:
        raise ConfigError("no CUBE URL — pass --url or set CUBE_URL")
    if not url.startswith(("http://", "https://")):
        raise ConfigError(f"CUBE URL must be http(s), got: {url}")
    if not url.endswith("/"):
        url += "/"

    username = args.user or env.get("CHRIS_SMOKE_USER") or ""
    if not username:
        raise ConfigError("no username — pass --user or set CHRIS_SMOKE_USER")

    password = args.password or env.get("CHRIS_SMOKE_PASSWORD") or ""
    if not password and env.get("CHRIS_SMOKE_PASSWORD_FILE"):
        password_file = Path(env["CHRIS_SMOKE_PASSWORD_FILE"])
        if not password_file.is_file():
            raise ConfigError(f"CHRIS_SMOKE_PASSWORD_FILE does not exist: {password_file}")
        password = password_file.read_text().strip()
    if not password:
        raise ConfigError("no password — set CHRIS_SMOKE_PASSWORD or CHRIS_SMOKE_PASSWORD_FILE")

    return SmokeConfig(
        cube_url=url,
        username=username,
        password=password,
        verify=_resolve_verify(args, env),
        timeout_s=_positive("timeout", args.timeout, env.get("SMOKE_TIMEOUT"), 600.0),
        poll_interval_s=_positive("poll interval", args.poll_interval,
                                  env.get("SMOKE_POLL_INTERVAL"), 5.0),
        request_timeout_s=_positive("request timeout", None,
                                    env.get("SMOKE_REQUEST_TIMEOUT"), 30.0),
        artifacts_dir=Path(args.artifacts_dir or env.get("SMOKE_ARTIFACTS_DIR")
                           or "smoke-artifacts"),
        keep=args.keep,
        kubeconfig=args.kubeconfig or env.get("SMOKE_KUBECONFIG") or None,
        namespace=env.get("SMOKE_NAMESPACE", "chris"),
        verbose=args.verbose,
    )


def _resolve_verify(args: argparse.Namespace, env: Mapping[str, str]) -> bool | str:
    if args.insecure:
        return False
    ca_bundle = args.ca_bundle or env.get("SMOKE_CA_BUNDLE")
    if ca_bundle:
        if not Path(ca_bundle).is_file():
            raise ConfigError(f"CA bundle does not exist: {ca_bundle}")
        return ca_bundle
    if env.get("SMOKE_INSECURE", "").lower() in ("1", "true", "yes"):
        return False
    return True


def _positive(label: str, flag: float | None, env_value: str | None,
              default: float) -> float:
    if flag is not None:
        value = flag
    elif env_value:
        try:
            value = float(env_value)
        except ValueError:
            raise ConfigError(f"{label} is not a number: {env_value}") from None
    else:
        value = default
    if value <= 0:
        raise ConfigError(f"{label} must be positive, got {value}")
    return value
