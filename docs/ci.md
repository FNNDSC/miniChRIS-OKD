# CI Wiring Notes (issue #131 — "suitable for later CI use")

The smoke test was built CI-first: env-driven configuration, a strict exit
code contract (`0` pass / `1` product failure / `2` setup failure), a JSON
verdict as the last stdout line, and self-contained failure artifacts. Actual
CI wiring is future work; this page records how to do it when the time comes.

## What a runner needs

1. **Network reach to the Route** — `https://cube.apps.<cluster domain>/`.
   For the reference deployment that domain resolves to a LAN IP, so the
   runner must be on that LAN: in practice a **self-hosted runner** on the
   harness box (or any LAN machine). A hosted runner only works against a
   deployment with a publicly resolvable Route.
2. **Credentials** — the seeded test user's password
   (`okd/state/auth/chris-test-user-password` on the harness host), exposed
   to the job as a secret.
3. **The router CA** (`just router-ca` → `okd/state/auth/router-ca.crt`) —
   or `SMOKE_INSECURE=1` as a last resort.
4. Python ≥ 3.10.

## Example: GitHub Actions, self-hosted runner on the harness host

On the harness box, `just smoke` already has everything wired — but note it
must run in the **live harness clone**, whose gitignored `okd/state/` holds
the credentials and router CA. A fresh `actions/checkout` workspace has no
`okd/state/` and would fail with exit 2 (setup, not product). Point the job
at the standing clone instead:

```yaml
name: chris-smoke
on:
  workflow_dispatch:        # promote to schedule/PR triggers when desired
env:
  HARNESS_DIR: /home/runner/miniChRIS-OKD   # the live harness clone
jobs:
  smoke:
    runs-on: [self-hosted, okd-harness]   # runner on the harness box
    steps:
      - name: Run smoke test
        working-directory: ${{ env.HARNESS_DIR }}
        run: just smoke
      - name: Keep failure diagnostics
        if: failure()
        uses: actions/upload-artifact@v4
        with:
          name: smoke-diagnostics
          path: ${{ env.HARNESS_DIR }}/okd/state/smoke-artifacts/
```

## Example: any LAN runner (not the harness host)

```yaml
      - uses: actions/checkout@v4
      - run: python3 -m venv .venv && .venv/bin/pip install ./smoke
      - name: Run smoke test
        env:
          CUBE_URL: ${{ vars.CUBE_URL }}
          CHRIS_SMOKE_USER: smoke
          CHRIS_SMOKE_PASSWORD: ${{ secrets.CHRIS_SMOKE_PASSWORD }}
          SMOKE_CA_BUNDLE: ci/router-ca.crt   # committed or fetched beforehand
          SMOKE_ARTIFACTS_DIR: smoke-artifacts
        run: .venv/bin/python -m chris_smoke
      - if: failure()
        uses: actions/upload-artifact@v4
        with: { name: smoke-diagnostics, path: smoke-artifacts/ }
```

## Parsing the verdict

The last stdout line is machine-readable regardless of outcome:

```sh
just smoke | tail -1 | jq .failed_step
```

Exit code `2` (setup problem: bad credentials, missing plugins, unreachable
Route — and, from `just smoke`, wrapper bootstrap failures like a missing
seeded password or unavailable router CA) should be treated as an
*infrastructure* alert, not a product regression — the journey never ran.

## Open items (deliberately deferred)

- Which repo hosts the workflow, and runner provisioning on the harness box
  (plan §15). Unit tests (`pytest smoke/tests`, no network needed) could run
  on hosted runners immediately.
- A `workflow_dispatch` input for `--keep` when debugging via CI.
- Against supported Red Hat OpenShift: same test, corporate DNS/PKI replaces
  sslip.io + `router-ca.crt` (see [okd-vs-ocp.md](okd-vs-ocp.md)).
