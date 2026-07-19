# chris/chrisomatic.yml.tpl — declarative seed of the harness-specific
# ChRIS state (test user + smoke-test plugin set), rendered by chris-seed.sh
# (credentials come from the chart's generated secrets; the rendered copy
# lives gitignored under okd/state/render/).
#
# The chart's heart pod separately registers the compute resource and the
# three fs-copy plugins CUBE hard-depends on (.Values.cube.plugins). The
# compute resource and pl-dircopy are re-declared here with the same
# chart-generated credentials/pins so re-running converges instead of
# conflicting. Pins recorded in docs/versions.md.
version: 1.2

on:
  cube_url: "${CUBE_INTERNAL_URL}"
  chris_superuser:
    username: "${CHRIS_SUPERUSER}"
    password: "${CHRIS_SUPERUSER_PASSWORD}"

cube:
  # Non-admin account the Phase 3 smoke test logs in as.
  users:
    - username: "${CHRIS_TEST_USER}"
      password: "${CHRIS_TEST_PASSWORD}"

  # Mirrors the chart's pfcon subchart: name/description are the chart's
  # values, credentials are chart-generated (secret <release>-pfcon).
  compute_resource:
    - name: "${PFCON_NAME}"
      url: "${PFCON_URL}"
      username: "${PFCON_USER}"
      password: "${PFCON_PASSWORD}"
      description: "${PFCON_DESCRIPTION}"
      innetwork: true

  # Smoke-test plugin set, resolved from the public peer CUBE
  # (https://cube.chrisproject.org):
  #   pl-dircopy      fs plugin — CUBE runs it internally (no-op container)
  #   pl-simpledsapp  ds plugin — exercises worker -> pfcon -> pman -> Job
  plugins:
    - name: pl-dircopy
      version: "3.0.0"
    - name: pl-simpledsapp
      version: "2.1.5"
