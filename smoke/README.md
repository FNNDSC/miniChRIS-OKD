# chris-smoke — functional smoke test for a ChRIS deployment

Proves a ChRIS instance *works*, not merely that its pods started
(HARBOR issue [#131](https://github.com/FNNDSC/HARBOR-planning/issues/131)):

```text
preflight   Route reachable → token auth → seeded plugins present
journey     upload test file → pl-dircopy (fs) → chained pl-simpledsapp (ds,
            i.e. the full worker → compute-backend → Kubernetes Job path)
            → poll to completion → download output → sha256 must match upload
cleanup     delete the feed + uploaded file (skipped with --keep)
```

The test speaks only the public CUBE REST API — it knows nothing about
pfcon/pman or the chart internals, so it survives a compute-backend swap.

## Exit codes (the CI contract)

| Code | Meaning |
|---|---|
| `0` | full journey passed |
| `1` | a journey step failed — ChRIS is deployed but functionally broken |
| `2` | configuration/preflight error — the invocation or deployment setup is wrong; the product was never exercised |

`just smoke` honors the same contract: any bootstrap failure in the wrapper
(missing python3, no seeded password, router CA unavailable, invalid harness
configuration) exits `2` and emits the same JSON verdict with
`"failed_step": "bootstrap"`.

The last stdout line is always a single-line JSON verdict
(`{"verdict": "pass", "exit_code": 0, "failed_step": null, "steps": [...], ...}`)
— from the wrapper as well as the Python CLI.

## Running from the harness

Everything is wired from harness state (URL, seeded `smoke` user, router CA,
admin kubeconfig for diagnostics):

```sh
just smoke                  # the whole journey, ~25 s on the reference box
just smoke --keep           # leave the feed + upload in place for inspection
just smoke --verbose        # stream every API call
just smoke-setup            # prepare the virtualenv only (e.g. CI pre-bake)
```

## Running from anywhere else (LAN client, CI)

The package is harness-agnostic — anything that can reach the Route can run
it. Configuration comes from env vars and/or flags (flags win):

```sh
python3 -m venv .venv && .venv/bin/pip install ./smoke

CUBE_URL=https://cube.apps.okd.10-0-0-33.sslip.io/api/v1/ \
CHRIS_SMOKE_USER=smoke \
CHRIS_SMOKE_PASSWORD_FILE=./chris-test-user-password \
SMOKE_CA_BUNDLE=./router-ca.crt \
.venv/bin/python -m chris_smoke
```

Get the two credential files from the harness host:
`okd/state/auth/chris-test-user-password` (created by `just chris-seed`) and
`okd/state/auth/router-ca.crt` (created by `just router-ca`).

| Env var | Flag | Default | Meaning |
|---|---|---|---|
| `CUBE_URL` | `--url` | — (required) | CUBE API base, `https://host/api/v1/` |
| `CHRIS_SMOKE_USER` | `--user` | — (required) | test-user name |
| `CHRIS_SMOKE_PASSWORD` | `--password` | — (required) | test-user password |
| `CHRIS_SMOKE_PASSWORD_FILE` | — | — | file alternative to the above |
| `SMOKE_CA_BUNDLE` | `--ca-bundle` | system CAs | CA file verifying the Route cert |
| `SMOKE_INSECURE` | `--insecure` | off | skip TLS verification (`1`/`true`/`yes`; dev fallback) |
| `SMOKE_TIMEOUT` | `--timeout` | `600` | plugin-run completion budget (s) |
| `SMOKE_POLL_INTERVAL` | `--poll-interval` | `5` | status poll cadence (s) |
| `SMOKE_REQUEST_TIMEOUT` | — | `30` | per-HTTP-request timeout (s) |
| `SMOKE_ARTIFACTS_DIR` | `--artifacts-dir` | `./smoke-artifacts` | failure diagnostics location |
| `SMOKE_KUBECONFIG` | `--kubeconfig` | unset | enables `oc` dumps in diagnostics |
| `SMOKE_NAMESPACE` | — | `chris` | namespace for `oc` dumps |
| — | `--keep` | off | skip cleanup, keep feed + upload |
| — | `--verbose` | off | log every API call |

## Failure diagnostics

On any failure the test writes `<artifacts>/<UTC timestamp>-<nonce>/`:

```text
trace.jsonl       every API call: timing, target, error
state.json        ids, paths, statuses, checksums the journey accumulated
instances.json    fresh plugin-instance details (status/error fields)
oc/*.txt          pods, events, jobs, PVCs + per-deployment logs
                  (only when oc + a kubeconfig are available)
```

and the failed run's feed is deliberately **not** deleted — it is evidence.
The exit code plus `failed_step` in the JSON verdict localizes the fault:
`CUBE route reachable` = routing/DNS/TLS, `authenticate` = auth stack,
`upload` = storage, `wait for completion` = workers/compute path,
`download`/`verify` = output registration or filesystem integrity.

## Design notes

- `chris_smoke/client.py` is the only module that speaks HTTP, and the only
  one importing [python-chrisclient](https://github.com/FNNDSC/python-chrisclient)
  — the same "thin adapter seam" pattern as the CUBE repo's `benchmarks/chris_api.py`.
  API drift gets absorbed there without touching scenario logic.
- Outputs are located via `userfiles/search/?fname=<output_path>` — in CUBE 6
  the userfiles queryset spans the whole `home/` tree, so it reaches plugin
  *output* files as well as uploads (the old `plugins/instances/N/files/`
  endpoint is gone, and `pl-dircopy` produces only a `.chrislink`; checksums
  are therefore taken on the *ds* plugin's physical output).
- `pl-simpledsapp` runs with `dummyInt=1`: pfcon rejects zero-argument
  instances and CUBE surfaces that as a silent `cancelled`
  (see `docs/troubleshooting.md`).
- Unit tests (`pip install -e './smoke[dev]' && pytest smoke/tests`) exercise
  the scenario, poller, verify, config, CLI exit contract, adapter seam,
  diagnostics layout, and verdict schema against a scripted in-memory CUBE
  (kept signature-conformant with the real adapter by a test); no network
  involved.
