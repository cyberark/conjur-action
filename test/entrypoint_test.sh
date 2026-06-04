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

    INPUT_AUTHN_TOKEN_FILE="fake_token_file"
    INPUT_AUTHN_ID="authn_id"
    INPUT_ACCOUNT="test_account"
    INPUT_CERTIFICATE="test_certificate"
    INPUT_URL="https://example.com"
    INPUT_HOST_ID="host/my-app"
    INPUT_API_KEY="api_key"
    INPUT_SECRETS="db/sqlusername|sql_username;db/sqlpassword|sql_password"
    GITHUB_ENV="/tmp/github_env"
    ACTIONS_ID_TOKEN_REQUEST_URL="http://github-dummy"
    ACTIONS_ID_TOKEN_REQUEST_TOKEN="dummy-token"

    handle_git_jwt() { echo "::debug No delta between iat [0] and epoch [0]"; }
    telemetry_header() { encoded="dummy-telemetry"; }

    curl() {
      if [[ "$*" == *"$ACTIONS_ID_TOKEN_REQUEST_TOKEN"* ]]; then
        [[ -n "${URL_CAPTURE_FILE:-}" ]] && printf '%s\n' "$*" >> "$URL_CAPTURE_FILE"
        [[ -n "${TOKEN_URL_FILE:-}" ]] && printf '%s\n' "$*" >> "$TOKEN_URL_FILE"
        echo '{"value":"dummy-jwt-token"}'
      elif [[ "$*" == *"authenticate"* ]]; then
        [[ -n "${URL_CAPTURE_FILE:-}" ]] && printf '%s\n' "$*" >> "$URL_CAPTURE_FILE"
        [[ -n "${AUTHN_URL_FILE:-}" ]] && printf '%s\n' "$*" >> "$AUTHN_URL_FILE"
        echo "dummy-token"
      else
        echo "fake_secret_value"
      fi
    }
}

tearDown() {
    IFS=$' \t\n'
    unalias cat 2>/dev/null || true
    unset -f curl handle_git_jwt telemetry_header 2>/dev/null || true
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

# Test 'create_pem' function
test_create_pem() {
    create_pem
    result=$(cat conjur_test_account.pem)
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

test_set_secrets_newline() {
    > "${GITHUB_ENV}"
    curl() {
        if [[ "$*" == *"authenticate"* ]]; then echo "dummy-token"
        else printf 'benign\nNEXT_VALUE=value1'
        fi
    }
    SECRETS="ci/lowpriv|LOWPRIV"
    set_secrets
    local content
    content=$(cat "${GITHUB_ENV}")
    assertContains "env file should use heredoc open" "${content}" "LOWPRIV<<EOF_"
    assertContains "secret body should contain embedded text" "${content}" "NEXT_VALUE=value1"
    # Secret is 2 lines, so heredoc is 4 lines (open + 2 body + close); any extra line means injection escaped
    assertEquals "env file should have exactly 4 lines" "4" "$(wc -l < "${GITHUB_ENV}")"
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
        if [[ "$*" == *"authenticate"* ]]; then echo "dummy-token"
        else printf 'line1\nline2'
        fi
    }
    SECRETS="ci/multiline|MULTI_SECRET"
    result=$(set_secrets)
    assertContains "should mask first line" "${result}" "::add-mask::line1"
    assertContains "should mask second line" "${result}" "::add-mask::line2"
}

# Run all tests
. /usr/bin/shunit2