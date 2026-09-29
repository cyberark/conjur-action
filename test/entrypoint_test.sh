#!/bin/bash

# Load the entrypoint.sh script
source ./entrypoint.sh

mock_cat() {
    if [[ "$1" == "fake_token_file" ]]; then
        echo "fake_token_value"
    else
        echo "File not found" >&2
        return 1
    fi
}

setUp() {
    echo "Setting up environment variables for tests"
    unset -f curl
    alias cat='mock_cat'

    CONJUR_TMP_DIR=$(mktemp -d)
    INPUT_AUTHN_TOKEN_FILE="fake_token_file"
    INPUT_AUTHN_ID="authn_id"
    INPUT_ACCOUNT="test_account"
    INPUT_CERTIFICATE="test_certificate"
    INPUT_URL="https://example.com"
    INPUT_HOST_ID="host/my-app"
    INPUT_API_KEY="api_key"
    INPUT_SECRETS="db/sqlusername|sql_username;db/sqlpassword|sql_password"
    GITHUB_ENV="/tmp/github_env"
    GITHUB_OUTPUT="/tmp/github_output"
    ACTIONS_ID_TOKEN_REQUEST_URL="http://github-dummy"
    # Deliberately distinct from the "dummy-token" string returned by the
    # authenticate branch below - if they matched, any test that calls
    # conjur_authn and then set_secrets in the same process (not a
    # subshell) would have set_secrets' curl call collide with the
    # id-token-request branch, since $token would equal this value too.
    ACTIONS_ID_TOKEN_REQUEST_TOKEN="gh-oidc-bearer-token"

    handle_git_jwt() { echo "::debug No delta between iat [0] and epoch [0]"; }
    telemetry_header() { encoded="dummy-telemetry"; }

    curl() {
      # Route by URL, not by credential value, so that moving credentials to
      # stdin (--config - / --data-binary @-) does not break routing logic.
      if [[ "$*" == *"$ACTIONS_ID_TOKEN_REQUEST_URL"* ]]; then
        [[ -n "${URL_CAPTURE_FILE:-}" ]] && printf '%s\n' "$*" >> "$URL_CAPTURE_FILE"
        [[ -n "${TOKEN_URL_FILE:-}" ]] && printf '%s\n' "$*" >> "$TOKEN_URL_FILE"
        [[ -n "${ARGV_CAPTURE_FILE:-}" ]] && printf '%s\n' "$*" >> "$ARGV_CAPTURE_FILE"
        echo '{"value":"dummy-jwt-token"}'
      elif [[ "$*" == *"authenticate"* ]]; then
        [[ -n "${URL_CAPTURE_FILE:-}" ]] && printf '%s\n' "$*" >> "$URL_CAPTURE_FILE"
        [[ -n "${AUTHN_URL_FILE:-}" ]] && printf '%s\n' "$*" >> "$AUTHN_URL_FILE"
        [[ -n "${ARGV_CAPTURE_FILE:-}" ]] && printf '%s\n' "$*" >> "$ARGV_CAPTURE_FILE"
        # conjur_curl uses --write-out '\n%{http_code}'; append a 200 status.
        printf 'dummy-token\n200'
      else
        [[ -n "${ARGV_CAPTURE_FILE:-}" ]] && printf '%s\n' "$*" >> "$ARGV_CAPTURE_FILE"
        # conjur_curl uses --write-out '\n%{http_code}'; append a 200 status.
        printf 'fake_secret_value\n200'
      fi
    }
}

tearDown() {
    IFS=$' \t\n'
    unalias cat 2>/dev/null || true
    unset -f curl handle_git_jwt telemetry_header 2>/dev/null || true
    if [[ -n "$CONJUR_TMP_DIR" ]]; then
        rm -rf -- "$CONJUR_TMP_DIR"
        CONJUR_TMP_DIR=""
    fi
}

# Test the 'get_token_from_file' function
test_get_token_from_file() {
    echo "fake_token_value" > "$INPUT_AUTHN_TOKEN_FILE"
    result=$(get_token_from_file)
    assertEquals "fake_token_value" "$result"
}

# Test 'get_token_from_file' when file doesn't exist
test_get_token_from_file_not_found() {
    INPUT_AUTHN_TOKEN_FILE="non_existent_file"
    result=$(get_token_from_file)
    assertEquals "::error:: Conjur authn token file non_existent_file not found on the host." "$result"
}

# Test the 'urlencode' function
test_urlencode_basic() {
  result=$(urlencode "hello world")
  assertContains "spaces should be percent-encoded" "$result" "hello%20world"
}

test_urlencode_special_characters() {
  result=$(urlencode "a+b&c/d?e=f")
  assertContains "special chars should be percent-encoded" "$result" "a%2Bb%26c%2Fd%3Fe%3Df"
}

# Test the real 'handle_git_jwt' implementation. setUp stubs it out for
# every other test, and a plain `unset -f` can't get the real one back
# since setUp's definition replaced it outright rather than shadowing it.
# Re-sourcing entrypoint.sh fresh inside a subshell gets the real
# implementation back (scoped to the subshell only) *and*, unlike
# `eval "$(declare -f ...)"`, preserves correct file:line attribution for
# coverage tooling, since the code still runs as part of entrypoint.sh
# rather than as a string re-evaluated at the call site.
test_handle_git_jwt_no_delta() {
  local payload jwt
  payload=$(printf '{"iat":%d}' "$((EPOCHSECONDS - 5))" | base64 | tr -d '=\n')
  jwt="header.${payload}.sig"
  result=$(source ./entrypoint.sh; handle_git_jwt "$jwt")
  assertContains "should report no delta" "$result" "::debug No delta"
}

test_handle_git_jwt_future_iat_sleeps() {
  local payload jwt
  payload=$(printf '{"iat":%d}' "$((EPOCHSECONDS + 3))" | base64 | tr -d '=\n')
  jwt="header.${payload}.sig"
  result=$(source ./entrypoint.sh; sleep() { echo "SLEPT:$1"; }; handle_git_jwt "$jwt")
  assertContains "should report a delta and sleep" "$result" "delta found"
}

test_handle_git_jwt_malformed_token_exits() {
  local exit_status
  # handle_git_jwt calls `exit` (not `return`) on this branch, so it must be
  # invoked in a subshell - otherwise it would terminate the whole test run.
  ( source ./entrypoint.sh; handle_git_jwt "not-a-real-jwt" ) >/dev/null 2>&1
  exit_status=$?
  assertEquals "should exit 1 on an unparseable payload" "1" "${exit_status}"
}

# Re-pads a base64url string (no '=' padding) back to standard base64 so
# `base64 -d` doesn't fail with "truncated input" - telemetry_header strips
# padding as part of making the value URL-safe.
decode_base64url() {
  local b64
  b64=$(printf '%s' "$1" | tr -- '-_' '+/')
  case $(( ${#b64} % 4 )) in
    2) b64="${b64}==" ;;
    3) b64="${b64}=" ;;
  esac
  printf '%s' "$b64" | base64 -d
}

# Test the real 'telemetry_header' implementation (same rationale as above:
# re-source fresh inside a subshell instead of eval'ing a captured
# function body, to keep coverage attribution correct).
#
# `script_dir` is derived from $0 in entrypoint.sh, which under `source`
# (as every test here does) points at this test file, not entrypoint.sh -
# that only matches production when entrypoint.sh runs directly. Override
# it after sourcing so this test targets the real CHANGELOG.md regardless
# of $0.
test_telemetry_header_reads_version_from_changelog() {
  local repo_root expected_version decoded
  repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  # Derive the expected version the same way telemetry_header does, so this
  # test doesn't need updating every time CHANGELOG.md is bumped.
  expected_version=$(grep -o '\[[0-9]\+\.[0-9]\+\.[0-9]\+\]' "$repo_root/CHANGELOG.md" | head -n 1 | tr -d '[]')
  decoded=$(source ./entrypoint.sh; script_dir="$repo_root"; telemetry_header; decode_base64url "$encoded")
  assertContains "should embed the real semver from CHANGELOG.md" "$decoded" "iv=${expected_version}"
}

test_telemetry_header_falls_back_without_changelog() {
  local decoded
  decoded=$(source ./entrypoint.sh; script_dir="/tmp/nonexistent-dir-$$"; telemetry_header; decode_base64url "$encoded")
  assertContains "should fall back to the default version" "$decoded" "iv=0.0.0-default"
}

# Test 'create_pem' function
test_create_pem() {
    create_pem
    result=$(cat "$CONJUR_TMP_DIR/conjur_test_account.pem")
    assertEquals "test_certificate" "$result"
}

# Test 'array_secrets' function
test_array_secrets_single_secret() {
  export INPUT_SECRETS="my-secret|MY_ENV"
  array_secrets

  assertEquals 1 "${#SECRETS[@]}"
  assertContains "single secret should be parsed" "${SECRETS[0]}" "my-secret|MY_ENV"
}

test_array_secrets_multiple_secrets() {
  export INPUT_SECRETS="db/password|DB_PASS;api/key|API_KEY"
  array_secrets

  assertEquals 2 "${#SECRETS[@]}"
  assertContains "first secret should be parsed" "${SECRETS[0]}" "db/password|DB_PASS"
  assertContains "second secret should be parsed" "${SECRETS[1]}" "api/key|API_KEY"
}

test_array_secrets_no_separator() {
  export INPUT_SECRETS="plainsecret"
  array_secrets

  assertEquals 1 "${#SECRETS[@]}"
  assertContains "secret without separator should be parsed" "${SECRETS[0]}" "plainsecret"
}

test_array_secrets_empty_string() {
  export INPUT_SECRETS=""
  array_secrets

  assertEquals 0 "${#SECRETS[@]}"
}

test_array_secrets_trailing_semicolon() {
  export INPUT_SECRETS="secret1|ENV1;"
  array_secrets
  
  assertEquals 1 "${#SECRETS[@]}" 
  assertContains "trailing semicolon should not create empty entry" "${SECRETS[0]}" "secret1|ENV1"
}

# Test 'conjur_authn' function for jwt
test_conjur_authn_jwt() {
  unset INPUT_HOST_ID

  result=$(conjur_authn)

  assertContains "should use JWT authn" "$result" "::debug Authenticate via Authn-JWT"
  assertContains "should use certificate" "$result" "::debug Authenticating with certificate"
  assertNotContains "should not add custom audience" "$result" "::debug Adding custom audience"
  assertNotContains "should not use host ID" "$result" "::debug Authenticate using Host ID"
}

test_conjur_authn_jwt_without_certificate() {
  unset INPUT_HOST_ID
  export INPUT_CERTIFICATE=""

  result=$(conjur_authn)

  assertContains "should use JWT authn" "$result" "::debug Authenticate via Authn-JWT"
  assertContains "should skip certificate" "$result" "::debug Authenticating without certificate"
  assertNotContains "should not add custom audience" "$result" "::debug Adding custom audience"
  assertNotContains "should not use host ID" "$result" "::debug Authenticate using Host ID"
}

test_conjur_authn_jwt_with_custom_audience() {
  export INPUT_AUDIENCE="my conjur audience"
  export INPUT_CERTIFICATE=""

  local url_capture_file
  url_capture_file=$(mktemp)
  export URL_CAPTURE_FILE="$url_capture_file"

  result=$(conjur_authn)

  assertContains "should use JWT authn" "$result" "::debug Authenticate via Authn-JWT"
  assertContains "should add custom audience" "$result" "::debug Adding custom audience"
  assertContains "should use host ID" "$result" "::debug Authenticate using Host ID"
  assertContains "should skip certificate" "$result" "::debug Authenticating without certificate"
  assertNotContains "should not use certificate" "$result" "::debug Authenticating with certificate"
  assertContains "audience param should be URL-encoded" "$(cat "$url_capture_file")" "audience=my%20conjur%20audience"
  rm -f "$url_capture_file"
  unset INPUT_AUDIENCE URL_CAPTURE_FILE
}

test_conjur_authn_jwt_without_audience_does_not_mutate_url() {
  unset INPUT_AUDIENCE
  export INPUT_CERTIFICATE=""

  local url_capture_file
  url_capture_file=$(mktemp)
  export URL_CAPTURE_FILE="$url_capture_file"

  result=$(conjur_authn)

  assertContains "should use JWT authn" "$result" "::debug Authenticate via Authn-JWT"
  assertNotContains "should not add audience" "$result" "::debug Adding custom audience"
  assertContains "should use host ID" "$result" "::debug Authenticate using Host ID"
  assertNotContains "should not use certificate" "$result" "::debug Authenticating with certificate"
  local captured
  captured=$(cat "$url_capture_file")
  assertNotContains "URL should not contain audience param" "$captured" "audience"
  rm -f "$url_capture_file"
}

test_conjur_authn_jwt_with_empty_audience_does_not_mutate_url() {
  export INPUT_AUDIENCE=""
  export INPUT_CERTIFICATE=""

  local url_capture_file
  url_capture_file=$(mktemp)
  export URL_CAPTURE_FILE="$url_capture_file"

  result=$(conjur_authn)

  assertContains "should use JWT authn" "$result" "::debug Authenticate via Authn-JWT"
  assertNotContains "empty audience should not add audience" "$result" "::debug Adding custom audience"
  assertContains "should use host ID" "$result" "::debug Authenticate using Host ID"
  assertNotContains "should not use certificate" "$result" "::debug Authenticating with certificate"
  local captured
  captured=$(cat "$url_capture_file")
  assertNotContains "URL should not contain audience param" "$captured" "audience"
  rm -f "$url_capture_file"
  unset INPUT_AUDIENCE URL_CAPTURE_FILE
}

test_conjur_authn_jwt_with_host_id() {
  unset INPUT_AUDIENCE
  export INPUT_CERTIFICATE=""

  local url_capture_file
  url_capture_file=$(mktemp)
  export URL_CAPTURE_FILE="$url_capture_file"

  result=$(conjur_authn)

  assertContains "should use JWT authn" "$result" "::debug Authenticate via Authn-JWT"
  assertContains "should use host ID" "$result" "::debug Authenticate using Host ID"
  assertNotContains "should not add audience" "$result" "::debug Adding custom audience"
  assertContains "should skip certificate" "$result" "::debug Authenticating without certificate"
  assertNotContains "should not use certificate" "$result" "::debug Authenticating with certificate"
  local captured
  captured=$(cat "$url_capture_file")
  assertContains "URL should include host ID segment" "$captured" "authn-jwt/authn_id/test_account/host%2Fmy-app/authenticate"
  rm -f "$url_capture_file"
  unset INPUT_HOST_ID URL_CAPTURE_FILE
}

test_conjur_authn_jwt_without_host_id_uses_base_url() {
  unset INPUT_HOST_ID
  unset INPUT_AUDIENCE
  export INPUT_CERTIFICATE=""

  local url_capture_file
  url_capture_file=$(mktemp)
  export URL_CAPTURE_FILE="$url_capture_file"

  result=$(conjur_authn)

  local captured
  captured=$(cat "$url_capture_file")
  assertContains "URL should use base path without host segment" "$captured" "authn-jwt/authn_id/test_account/authenticate"
  assertContains "should use JWT authn" "$result" "::debug Authenticate via Authn-JWT"
  assertNotContains "should not add audience" "$result" "::debug Adding custom audience"
  assertNotContains "should not use host ID" "$result" "::debug Authenticate using Host ID"
  assertContains "should skip certificate" "$result" "::debug Authenticating without certificate"
  assertNotContains "should not use certificate" "$result" "::debug Authenticating with certificate"
  assertNotContains "URL should not contain host segment" "$captured" "test_account/host"
  rm -f "$url_capture_file"
  unset URL_CAPTURE_FILE
}

test_conjur_authn_jwt_with_certificate() {
  unset INPUT_HOST_ID
  unset INPUT_AUDIENCE

  result=$(conjur_authn)

  assertContains "should use JWT authn" "$result" "::debug Authenticate via Authn-JWT"
  assertContains "should use certificate" "$result" "::debug Authenticating with certificate"
  assertNotContains "should not add audience" "$result" "::debug Adding custom audience"
  assertNotContains "should not use host ID" "$result" "::debug Authenticate using Host ID"
}

test_conjur_authn_jwt_with_audience_and_host_id() {
  export INPUT_AUDIENCE="my conjur audience"
  export INPUT_CERTIFICATE=""

  local token_url_file authn_url_file
  token_url_file=$(mktemp)
  authn_url_file=$(mktemp)
  export TOKEN_URL_FILE="$token_url_file"
  export AUTHN_URL_FILE="$authn_url_file"

  result=$(conjur_authn)

  # Audience applied to the OIDC token request
  assertContains "should use JWT authn" "$result" "::debug Authenticate via Authn-JWT"
  assertContains "should add custom audience" "$result" "::debug Adding custom audience"
  assertContains "should use host ID" "$result" "::debug Authenticate using Host ID"
  assertContains "should skip certificate" "$result" "::debug Authenticating without certificate"
  assertNotContains "should not use certificate" "$result" "::debug Authenticating with certificate"
  # Audience applied to the OIDC token request
  assertContains "audience param should be URL-encoded" "$(cat "$token_url_file")" "audience=my%20conjur%20audience"
  # Host ID applied to the Conjur authenticate URL
  assertContains "URL should include host ID segment" "$(cat "$authn_url_file")" "authn-jwt/authn_id/test_account/host%2Fmy-app/authenticate"

  rm -f "$token_url_file" "$authn_url_file"
  unset INPUT_HOST_ID INPUT_AUDIENCE TOKEN_URL_FILE AUTHN_URL_FILE
}

# Test 'conjur_authn' function for authn-cert
test_conjur_authn_cert_basic() {
    export INPUT_AUTHN_ID=""
    export INPUT_AUTHN_CERT_ID="acme-vm"
    export INPUT_CLIENT_CERT="fakecert"
    export INPUT_CLIENT_KEY="fakekey"

    result=$(conjur_authn)

    assertContains "should use cert authn" "$result" "::debug Authenticate via Authn-Cert"
    assertNotContains "should not use JWT authn" "$result" "::debug Authenticate via Authn-JWT"
    assertNotContains "should not use API key authn" "$result" "::debug Authenticate using Host ID & API Key"

    unset INPUT_AUTHN_CERT_ID INPUT_CLIENT_CERT INPUT_CLIENT_KEY
}

test_conjur_authn_cert_url_construction() {
    export INPUT_AUTHN_ID=""
    export INPUT_AUTHN_CERT_ID="acme-vm"
    export INPUT_CLIENT_CERT="fakecert"
    export INPUT_CLIENT_KEY="fakekey"
    export INPUT_CERTIFICATE=""

    local authn_url_file
    authn_url_file=$(mktemp)
    export AUTHN_URL_FILE="$authn_url_file"

    conjur_authn

    local captured
    captured=$(cat "$authn_url_file")
    assertContains "URL should use authn-cert path with encoded host ID" "$captured" \
        "authn-cert/acme-vm/test_account/host%2Fmy-app/authenticate"

    rm -f "$authn_url_file"
    unset INPUT_AUTHN_CERT_ID INPUT_CLIENT_CERT INPUT_CLIENT_KEY AUTHN_URL_FILE
}

test_conjur_authn_cert_with_server_certificate() {
    export INPUT_AUTHN_ID=""
    export INPUT_AUTHN_CERT_ID="acme-vm"
    export INPUT_CLIENT_CERT="fakecert"
    export INPUT_CLIENT_KEY="fakekey"

    result=$(conjur_authn)

    assertContains "should use cert authn" "$result" "::debug Authenticate via Authn-Cert"
    assertContains "should report server certificate in use" "$result" "::debug Authenticating with certificate"

    unset INPUT_AUTHN_CERT_ID INPUT_CLIENT_CERT INPUT_CLIENT_KEY
}

test_conjur_authn_cert_without_server_certificate() {
    export INPUT_AUTHN_ID=""
    export INPUT_AUTHN_CERT_ID="acme-vm"
    export INPUT_CLIENT_CERT="fakecert"
    export INPUT_CLIENT_KEY="fakekey"
    export INPUT_CERTIFICATE=""

    result=$(conjur_authn)

    assertContains "should use cert authn" "$result" "::debug Authenticate via Authn-Cert"
    assertContains "should report no server certificate" "$result" "::debug Authenticating without certificate"

    unset INPUT_AUTHN_CERT_ID INPUT_CLIENT_CERT INPUT_CLIENT_KEY
}

test_conjur_authn_cert_without_host_id_uses_spiffe_url() {
    # SPIFFE host-mode (self-hosted): host_id is optional — URL must NOT include
    # the workload segment when host_id is absent.
    export INPUT_AUTHN_ID=""
    export INPUT_AUTHN_CERT_ID="acme-vm"
    export INPUT_CLIENT_CERT="fakecert"
    export INPUT_CLIENT_KEY="fakekey"
    export INPUT_CERTIFICATE=""
    local saved_host_id="$INPUT_HOST_ID"
    unset INPUT_HOST_ID

    local authn_url_file
    authn_url_file=$(mktemp)
    export AUTHN_URL_FILE="$authn_url_file"

    local result exit_status
    result=$(conjur_authn 2>&1)
    exit_status=$?

    assertEquals "should exit 0 in SPIFFE mode (no host_id)" "0" "${exit_status}"
    assertContains "should use cert authn" "$result" "::debug Authenticate via Authn-Cert"
    assertNotContains "should not log host ID step" "$result" "::debug Authenticate using Host ID"

    local captured
    captured=$(cat "$authn_url_file")
    assertContains "URL should NOT contain workload segment" "$captured" \
        "authn-cert/acme-vm/test_account/authenticate"
    assertNotContains "URL should not have workload path" "$captured" \
        "test_account/host"

    rm -f "$authn_url_file"
    export INPUT_HOST_ID="$saved_host_id"
    unset INPUT_AUTHN_CERT_ID INPUT_CLIENT_CERT INPUT_CLIENT_KEY AUTHN_URL_FILE
}

test_conjur_authn_cert_without_client_cert_exits() {
    export INPUT_AUTHN_ID=""
    export INPUT_AUTHN_CERT_ID="acme-vm"
    export INPUT_CLIENT_CERT=""
    export INPUT_CLIENT_KEY="fakekey"

    local result exit_status
    result=$(conjur_authn 2>&1)
    exit_status=$?

    assertEquals "should exit 1 when client_cert is missing" "1" "${exit_status}"
    assertContains "should emit error for missing client_cert" "${result}" "::error::"

    unset INPUT_AUTHN_CERT_ID INPUT_CLIENT_CERT INPUT_CLIENT_KEY
}

test_conjur_authn_cert_without_client_key_exits() {
    export INPUT_AUTHN_ID=""
    export INPUT_AUTHN_CERT_ID="acme-vm"
    export INPUT_CLIENT_CERT="fakecert"
    export INPUT_CLIENT_KEY=""

    local result exit_status
    result=$(conjur_authn 2>&1)
    exit_status=$?

    assertEquals "should exit 1 when client_key is missing" "1" "${exit_status}"
    assertContains "should emit error for missing client_key" "${result}" "::error::"

    unset INPUT_AUTHN_CERT_ID INPUT_CLIENT_CERT INPUT_CLIENT_KEY
}

# Test 'conjur_authn' function for api_key
test_conjur_authn_api_key() {
  INPUT_AUTHN_ID=""
  result=$(conjur_authn)

  assertContains "should use API key authn" "$result" "::debug Authenticate using Host ID & API Key"
  assertContains "should use certificate" "$result" "::debug Authenticating with certificate"
  assertNotContains "should not use JWT authn" "$result" "::debug Authenticate via Authn-JWT"
}

test_conjur_authn_api_key_without_certificate() {
  INPUT_AUTHN_ID=""
  INPUT_CERTIFICATE=""
  result=$(conjur_authn)

  assertContains "should use API key authn" "$result" "::debug Authenticate using Host ID & API Key"
  assertContains "should skip certificate" "$result" "::debug Authenticating without certificate"
  assertNotContains "should not use JWT authn" "$result" "::debug Authenticate via Authn-JWT"
}

# Test 'validate_url' function
test_validate_url_https_passes_silently() {
    INPUT_URL="https://example.com"
    result=$(validate_url)
    assertEquals "" "$result"
}

test_validate_url_http_with_insecure_flag_emits_warning() {
    INPUT_URL="http://example.com"
    INPUT_ALLOW_INSECURE_CONNECTIONS="true"
    result=$(validate_url)
    assertContains "should emit warning for HTTP with flag" "$result" "::warning::"
    unset INPUT_ALLOW_INSECURE_CONNECTIONS
}

test_validate_url_http_without_insecure_flag_exits_with_error() {
    INPUT_URL="http://example.com"
    INPUT_ALLOW_INSECURE_CONNECTIONS="false"
    result=$(validate_url; echo "exit:$?")
    assertContains "should emit error for HTTP without flag" "$result" "::error::"
    unset INPUT_ALLOW_INSECURE_CONNECTIONS
}

test_validate_url_http_with_unset_insecure_flag_exits_with_error() {
    INPUT_URL="http://example.com"
    unset INPUT_ALLOW_INSECURE_CONNECTIONS
    result=$(validate_url; echo "exit:$?")
    assertContains "should emit error for HTTP with unset flag" "$result" "::error::"
}

# Test 'set_secrets' function
test_set_secrets_empty() {
    SECRETS=""
    result=$(set_secrets)
    assertContains "should report no secrets error" "$result" "::error::No secret found for retrieval from Conjur Vault"
}

test_set_secrets() {
    > "${GITHUB_ENV}"
    SECRETS="db/sqlusername|sql_username"
    result=$(set_secrets)
    assertContains "should retrieve with certificate" "$result" "::debug Retrieving secret with certificate"
    output=$(cat "${GITHUB_ENV}")
    assertContains "env file should have heredoc open" "$output" "SQL_USERNAME<<EOF_"
    assertContains "env file should contain secret value" "$output" "fake_secret_value"
}

test_set_secrets_no_separator_nested_path() {
    > "${GITHUB_ENV}"
    SECRETS="db/nested/sql_password"
    result=$(set_secrets)
    output=$(cat "${GITHUB_ENV}")
    assertContains "env var should be the last path segment, uppercased" "$output" "SQL_PASSWORD<<EOF_"
    assertContains "secret value should be present" "$output" "fake_secret_value"
}

test_set_secrets_without_certificate() {
    > "${GITHUB_ENV}"
    INPUT_CERTIFICATE=""
    SECRETS="db/sqlusername|sql_username"
    result=$(set_secrets)
    assertContains "should retrieve without certificate" "$result" "::debug Retrieving secret without certificate"
    INPUT_CERTIFICATE="test_certificate"
}

test_set_secrets_rejects_delimiter_collision() {
    > "${GITHUB_ENV}"
    curl() {
        if [[ "$*" == *"authenticate"* ]]; then printf 'dummy-token\n200'
        else printf 'before EOF_424242 after\n200'
        fi
    }
    SECRETS="ci/collide|COLLIDE_SECRET"
    local result exit_status
    # Unsetting RANDOM and reassigning it strips its "special" dynamic
    # behavior in bash, making $RANDOM deterministic - this lets us force
    # the exact delimiter set_secrets will generate
    # (EOF_$RANDOM$RANDOM$RANDOM -> EOF_424242) without touching production
    # code. Once stripped, RANDOM can't regain its dynamic behavior even via
    # another unset, so this runs in a command-substitution subshell to keep
    # the mutation from leaking into the rest of this test process.
    result=$(unset RANDOM; RANDOM=42; set_secrets 2>&1); exit_status=$?
    assertEquals "should exit 1 on delimiter collision" "1" "${exit_status}"
    assertContains "should emit collision error" "${result}" "::error::Secret value contains env delimiter"
}

test_set_secrets_newline() {
    > "${GITHUB_ENV}"
    curl() {
        if [[ "$*" == *"authenticate"* ]]; then printf 'dummy-token\n200'
        else printf 'benign\nNEXT_VALUE=value1\n200'
        fi
    }
    INPUT_SECRETS="ci/lowpriv|LOWPRIV"
    array_secrets
    set_secrets
    local content
    content=$(cat "${GITHUB_ENV}")
    assertContains "env file should use heredoc open" "${content}" "LOWPRIV<<EOF_"
    assertContains "secret body should contain embedded text" "${content}" "NEXT_VALUE=value1"
    # Secret is 2 lines, so heredoc is 4 lines (open + 2 body + close); any extra line means injection escaped
    # `wc -l` pads its count with leading whitespace on BSD/macOS (unlike
    # GNU coreutils), so strip whitespace before comparing.
    assertEquals "env file should have exactly 4 lines" "4" "$(wc -l < "${GITHUB_ENV}" | tr -d '[:space:]')"
}

test_set_secrets_invalid_envvar() {
    > "${GITHUB_ENV}"                                                                                                                                                                                          
    SECRETS="ci/var|bad=name"                                                                                                                                                                                  
    local result exit_status                                                                                                                                                                                   
    result=$(set_secrets 2>&1); exit_status=$?                                                                                                                                                                 
    assertEquals "should exit 1 for invalid envVar" "1" "${exit_status}"                                                                                                                                       
    assertContains "should emit ::error:: for invalid envVar" "${result}" "::error::"                                                                                                                          
}

test_set_secrets_windows_style_envvar() {
    > "${GITHUB_ENV}"
    SECRETS="ci/var|My-App.Secret(1)"
    result=$(set_secrets)
    output=$(cat "${GITHUB_ENV}")
    assertContains "windows-style name with hyphens/dots/parens should be written" \
        "$output" "MY-APP.SECRET(1)<<EOF_"
    assertContains "secret value should be present" "$output" "fake_secret_value"
    assertNotContains "should not emit error for windows-style name" "$result" "::error::"
}


test_set_secrets_multiline_mask() {
    > "${GITHUB_ENV}"
    curl() {
        if [[ "$*" == *"authenticate"* ]]; then printf 'dummy-token\n200'
        else printf 'line1\nline2\n200'
        fi
    }
    SECRETS="ci/multiline|MULTI_SECRET"
    result=$(set_secrets)
    assertContains "should mask first line" "${result}" "::add-mask::line1"
    assertContains "should mask second line" "${result}" "::add-mask::line2"
}

# Test the 'main' dispatch as a whole (individual tests above only exercise
# its sub-functions directly)
test_main_uses_conjur_authn_when_no_token_file() {
    unset INPUT_AUTHN_TOKEN_FILE
    > "${GITHUB_ENV}"
    result=$(main 2>&1)
    assertContains "should authenticate via conjur_authn" "$result" "::debug Authenticate via Authn-JWT"
    output=$(cat "${GITHUB_ENV}")
    assertContains "should still retrieve secrets" "$output" "fake_secret_value"
}

test_main_uses_token_file_when_set() {
    echo "fake_token_value" > "$INPUT_AUTHN_TOKEN_FILE"
    > "${GITHUB_ENV}"
    result=$(main 2>&1)
    assertNotContains "should skip conjur_authn entirely" "$result" "::debug Authenticate"
    output=$(cat "${GITHUB_ENV}")
    assertContains "should still retrieve secrets using the file-based token" "$output" "fake_secret_value"
}

# API key must be delivered via --data-binary @- (stdin), never via --data ARG.
test_api_key_not_exposed_in_curl_argv() {
    INPUT_AUTHN_ID=""
    local argv_capture_file
    argv_capture_file=$(mktemp)
    export ARGV_CAPTURE_FILE="$argv_capture_file"

    conjur_authn >/dev/null 2>&1

    local captured
    captured=$(cat "$argv_capture_file")
    assertNotContains "API key must not appear in curl argv" "$captured" "$INPUT_API_KEY"

    rm -f "$argv_capture_file"
    unset ARGV_CAPTURE_FILE
}

# GitHub OIDC bearer token must be delivered via --config - (stdin), never via -H ARG.
test_oidc_bearer_token_not_exposed_in_curl_argv() {
    local saved_host_id="$INPUT_HOST_ID"
    unset INPUT_HOST_ID
    local argv_capture_file
    argv_capture_file=$(mktemp)
    export ARGV_CAPTURE_FILE="$argv_capture_file"

    conjur_authn >/dev/null 2>&1

    local captured
    captured=$(cat "$argv_capture_file")
    assertNotContains "OIDC bearer token must not appear in curl argv" \
        "$captured" "$ACTIONS_ID_TOKEN_REQUEST_TOKEN"

    rm -f "$argv_capture_file"
    unset ARGV_CAPTURE_FILE
    export INPUT_HOST_ID="$saved_host_id"
}

# JWT returned by the OIDC endpoint must not appear on the Conjur authn-jwt call argv.
test_jwt_not_exposed_in_curl_argv() {
    local saved_host_id="$INPUT_HOST_ID"
    unset INPUT_HOST_ID
    local argv_capture_file
    argv_capture_file=$(mktemp)
    export ARGV_CAPTURE_FILE="$argv_capture_file"

    conjur_authn >/dev/null 2>&1

    local captured
    captured=$(cat "$argv_capture_file")
    assertNotContains "JWT must not appear in curl argv (authn-jwt POST body)" \
        "$captured" "dummy-jwt-token"

    rm -f "$argv_capture_file"
    unset ARGV_CAPTURE_FILE
    export INPUT_HOST_ID="$saved_host_id"
}

# Conjur session token must not appear in curl argv; it is written to a private
# temp file and passed via --header @file, never via -H ARG.
test_session_token_not_exposed_in_curl_argv() {
    > "${GITHUB_ENV}"
    local argv_capture_file
    argv_capture_file=$(mktemp)
    export ARGV_CAPTURE_FILE="$argv_capture_file"

    # Set a recognisable token value then call set_secrets directly.
    local fixed_token="fixed-session-token-$$"
    token="$fixed_token"
    SECRETS="ci/myvar|MY_VAR"
    array_secrets
    set_secrets >/dev/null 2>&1

    local captured
    captured=$(cat "$argv_capture_file")
    assertNotContains "session token must not appear in curl argv (secret retrieval)" \
        "$captured" "$fixed_token"

    rm -f "$argv_capture_file"
    unset ARGV_CAPTURE_FILE token
}

# Run all tests
. /usr/bin/shunit2
