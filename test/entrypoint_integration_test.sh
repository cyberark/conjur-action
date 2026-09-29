#!/bin/bash

# Integration test that runs entrypoint.sh as a real subprocess (`bash
# entrypoint.sh`), with a fake `curl` on PATH instead of the usual
# function-override mock used by entrypoint_test.sh.
#
# Every test in entrypoint_test.sh sources entrypoint.sh, so
# "${BASH_SOURCE[0]}" is this test file, never "${0}" - the top-level
#   if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then main "$@"; fi
# guard can never take its true branch under sourcing, no matter what those
# tests do. Only running entrypoint.sh directly as `bash entrypoint.sh` (or
# `./entrypoint.sh`) makes BASH_SOURCE[0] and $0 the same value, so this is
# the only way to exercise that line.

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

setUp() {
    ORIGINAL_PATH="$PATH"
    FAKE_BIN_DIR=$(mktemp -d)
    cat > "$FAKE_BIN_DIR/curl" <<'FAKE_CURL'
#!/bin/bash
args="$*"
if [[ "$args" == *"$ACTIONS_ID_TOKEN_REQUEST_URL"* ]]; then
    # OIDC token request: return a real, well-formed JWT with an iat safely
    # in the past so handle_git_jwt takes its no-delta branch and returns
    # immediately instead of sleeping.
    payload=$(printf '{"iat":%d}' "$(($(date +%s) - 5))" | base64 | tr -d '=\n')
    printf '{"value":"header.%s.sig"}' "$payload"
elif [[ "$args" == *"authenticate"* ]]; then
    printf 'dummy-token\n200'
else
    printf 'fake_secret_value\n200'
fi
FAKE_CURL
    chmod +x "$FAKE_BIN_DIR/curl"

    GITHUB_ENV=$(mktemp)
    PATH="$FAKE_BIN_DIR:$PATH"
    export GITHUB_ENV PATH

    export INPUT_URL="https://example.com"
    export INPUT_ACCOUNT="test_account"
    export INPUT_CERTIFICATE="test_certificate"
    export INPUT_AUTHN_ID="authn_id"
    export INPUT_HOST_ID="host/my-app"
    export INPUT_API_KEY="api_key"
    export INPUT_SECRETS="db/sqlusername|sql_username"
    export INPUT_AUTHN_TOKEN_FILE=""
    export INPUT_ALLOW_INSECURE_CONNECTIONS=""
    export INPUT_AUDIENCE=""
    export ACTIONS_ID_TOKEN_REQUEST_URL="http://github-dummy"
    export ACTIONS_ID_TOKEN_REQUEST_TOKEN="gh-oidc-bearer-token"
}

tearDown() {
    PATH="$ORIGINAL_PATH"
    export PATH
    rm -rf "$FAKE_BIN_DIR"
    rm -f "$GITHUB_ENV"
}

test_entrypoint_runs_main_when_executed_directly() {
    local output exit_status
    output=$(bash "$REPO_ROOT/entrypoint.sh" 2>&1)
    exit_status=$?

    assertEquals "entrypoint.sh should exit 0 on success" "0" "${exit_status}"
    assertContains "should authenticate via Authn-JWT" "$output" "::debug Authenticate via Authn-JWT"
    assertContains "should mask the retrieved secret" "$output" "::add-mask::fake_secret_value"

    local env_contents
    env_contents=$(cat "$GITHUB_ENV")
    assertContains "GITHUB_ENV should contain the uppercased env var name" "$env_contents" "SQL_USERNAME<<EOF_"
    assertContains "GITHUB_ENV should contain the retrieved secret value" "$env_contents" "fake_secret_value"
}

test_entrypoint_exits_nonzero_on_disallowed_http() {
    export INPUT_URL="http://example.com"
    local output exit_status
    output=$(bash "$REPO_ROOT/entrypoint.sh" 2>&1)
    exit_status=$?

    assertEquals "entrypoint.sh should exit 1 for disallowed http" "1" "${exit_status}"
    assertContains "should emit an error" "$output" "::error::HTTP connections are not allowed"
}

. /usr/bin/shunit2
