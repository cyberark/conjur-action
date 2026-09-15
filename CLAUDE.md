# CLAUDE.md

## Overview

This repo (`cyberark/conjur-action`) is a **GitHub Action** ("CyberArk Conjur Secret Fetcher") that securely
retrieves secrets from a **CyberArk Conjur** Secrets Manager (Enterprise or Open Source) instance and injects
them into a GitHub Actions workflow as masked environment variables. It runs as a **Docker-based** GitHub
Action (see `runs.using: 'docker'` in `action.yml`): GitHub builds/pulls the published image
(`cyberark/conjur-action:<version>`) and executes it with the action's inputs passed as positional args. It
supports Host ID + API Key authentication, JWT authentication (`authn-jwt`, using the workflow's OIDC token),
and certificate/mTLS authentication (`authn-cert`). It fits into the Conjur ecosystem as a CI/CD integration
point, letting workflows pull secrets (DB creds, API keys, etc.) at runtime instead of hardcoding them.

## Tech stack

- **Shell (Bash)** — all logic lives in `entrypoint.sh`, invoked via the Docker `ENTRYPOINT`.
- **Alpine Linux** base image (`Dockerfile`) with `bash`, `curl`, `jq`, `openssl`.
- **Ruby** (Dockerfile.test) is used only for the test/coverage harness (`bashcov`, `simplecov`), not for
  action logic.
- Talks to Conjur exclusively over its HTTP(S) REST API via `curl`.

## Build

- Production image: `docker build -f Dockerfile -t conjur-action .`
- Full release packaging (tarball + image, uses `bin/Dockerfile.build`): `./bin/build_release`
  (requires `bin/build_utils`; expects to run from repo root).

## Test

- Unit + integration tests are `shunit2`-based Bash test scripts: `test/entrypoint_test.sh` (mocks
  `curl`/network calls) and `test/entrypoint_integration_test.sh`. They `source ./entrypoint.sh`, so they
  must be run with the repo root as the working directory.
- Preferred way to run the full suite with coverage (mirrors CI): `./bin/coverage.sh` — builds
  `Dockerfile.test` and runs both test scripts through `bashcov`, then generates a JUnit report via
  `bin/generate_junit_report.sh` into `./output/`.
- Direct/manual run (outside Docker, needs `shunit2` installed): `bash test/entrypoint_test.sh`.

## Repo structure

- `action.yml` — Action metadata: declares all inputs (`url`, `account`, `host_id`, `api_key`,
  `authn_token_file`, `authn_id`, `authn_cert_id`, `client_cert`, `client_key`, `secrets`, `certificate`,
  `allow_insecure_connections`, `audience`) and maps them positionally into the Docker container's args.
- `entrypoint.sh` — All runtime logic: URL/TLS validation, auth (`conjur_authn` — API key, JWT, or cert
  flow), secret fetching (`set_secrets`), masking (`::add-mask::`), and writing results to `$GITHUB_ENV`.
  Sourced directly by the test suite, so functions must remain individually testable/mockable.
- `Dockerfile` — production image; runs as non-root user `1001`; copies only `entrypoint.sh` and
  `CHANGELOG.md`.
- `Dockerfile.test` — Ruby-based image for running the shunit2/bashcov test suite.
- `bin/` — build/release/CI tooling (`build_release`, `build_utils`, `coverage.sh`,
  `generate_junit_report.sh`, `publish_container_images`, Docker Compose files for local Conjur setups,
  `conjur-intro` git submodule for local demo environments).
- `test/` — `entrypoint_test.sh` (unit, mocked curl), `entrypoint_integration_test.sh` (integration),
  `test_helper.rb` (coverage/report glue).
- `github-app-id.yml`, `github-authn-jwt.yml` — sample Conjur policy files for setting up JWT/App-ID
  authenticators, referenced from `README.md`.
- `Jenkinsfile` — CI/CD pipeline (build, security scans, release/promotion) used by CyberArk's internal
  Jenkins, not GitHub Actions.
- `CHANGELOG.md` — version is parsed at runtime by `entrypoint.sh` (`telemetry_header`) for telemetry; keep
  its `[x.y.z]` heading format intact.

## Conventions / gotchas

- **Secrets syntax**: the `secrets` input is a `;`-delimited list of `conjurVariableId[|ENV_VAR_NAME]`
  pairs (no spaces). If no env var name is given, it's derived from the last path segment of the variable
  ID, upper-cased.
- **Security-sensitive shell code**: `entrypoint.sh` enforces HTTPS by default (`--proto '=https'`),
  validates env var names before writing to `$GITHUB_ENV` (rejects newlines, `=`, `<<`), uses a random
  heredoc delimiter per secret, and masks every line of a secret via `::add-mask::` before it's echoed
  anywhere. Preserve these guards when editing — this is the core threat-mitigation logic.
- Only one auth method should be exercised per run: **API Key** (`host_id`+`api_key`), **JWT**
  (`authn_id`, optional `host_id`/`audience`), or **Cert/mTLS** (`authn_cert_id`+`client_cert`+`client_key`).
  `conjur_authn` branches on which inputs are present, in that precedence order.
- Docker image is pinned to a specific `alpine` digest and pinned apk package versions in `Dockerfile` —
  bump deliberately, not casually, since this is a security-focused action.
- Runs as non-root (UID 1001) with a read-only entrypoint script (`chmod a-w`); avoid changes that assume
  write access to `/conjur-action`.
- Tests rely on function-level mocking (e.g. `curl`, `handle_git_jwt`, `telemetry_header` are overridden in
  `setUp`) since `entrypoint.sh` is sourced, not executed as a subprocess — keep new logic in small,
  mockable functions.
