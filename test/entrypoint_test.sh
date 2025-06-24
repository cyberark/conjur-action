
#!/bin/bash

# Load the entrypoint.sh script
script=$(awk '!/^[[:space:]]*main(\(\))?[[:space:]]*("\$@")?[[:space:]]*$/' ./entrypoint.sh)
eval "$script"

assertContains() {
  local string="$1"
  local substring="$2"

  echo "$string" | grep -qF -- "$substring"
  local status=$?

  if [[ $status -ne 0 ]]; then
    echo "Expected to find '$substring' in '$string'"
    return 1
  fi
}

assertIntegerEquals() {
  local expected=$1
  local actual=$2
  
  if ! [[ "$expected" =~ ^-?[0-9]+$ ]]; then
    echo "FAIL: Expected value '$expected' is not an integer."
    return 1
  fi

  if ! [[ "$actual" =~ ^-?[0-9]+$ ]]; then
    echo "FAIL: Actual value '$actual' is not an integer."
    return 1
  fi

  if [[ "$expected" -ne "$actual" ]]; then
    echo "FAIL: Expected '$expected', but got '$actual'"
    return 1
  fi
  
  return 0
}

mock_curl() {
    if [[ "$1" == *"authn-jwt"* ]]; then
        echo "::debug Authenticate via Authn-JWT"
        echo "::debug Authenticating with certificate"
        echo "::debug Authenticated via Authn-JWT"
    elif [[ "$1" == *"authn"* ]]; then
        echo "::debug Authenticate using Host ID & API Key"
        echo "::debug Authenticating without certificate"
    else
        echo "fake_secret_value"
    fi
}

oneTimeSetUp() {
  MOCK_CURL_DIR=$(mktemp -d)

  cat <<'EOF' > "$MOCK_CURL_DIR/curl"
#!/bin/bash
source "$MOCK_CURL_SCRIPT"
mock_curl "$@"
EOF

  chmod +x "$MOCK_CURL_DIR/curl"

  ORIGINAL_PATH="$PATH"
  export PATH="$MOCK_CURL_DIR:$PATH"
  export -f mock_curl
  export MOCK_CURL_SCRIPT="$(mktemp)"
  declare -f mock_curl > "$MOCK_CURL_SCRIPT"
}

oneTimeTearDown() {
  export PATH="$ORIGINAL_PATH"
  rm -rf "$MOCK_CURL_DIR"
  rm -f "$MOCK_CURL_SCRIPT"
}

mock_cat() {
    if [[ "$1" == "fake_token_file" ]]; then
        echo "fake_token_value"
    else
        echo "File not found" >&2
        return 1
    fi
}


mock_echo() {
    echo "echo called with args: $*"
}



test_setup() {
    alias curl='mock_curl'
    alias cat='mock_cat'
    alias echo='mock_echo'

    INPUT_AUTHN_TOKEN_FILE="fake_token_file"
    INPUT_AUTHN_ID="authn_id"
    INPUT_ACCOUNT="test_account"
    INPUT_CERTIFICATE="test_certificate"
    INPUT_URL="https://example.com"
    INPUT_HOST_ID="host_id"
    INPUT_API_KEY="api_key"
    INPUT_SECRETS="db/sqlusername|sql_username;db/sqlpassword|sql_password"
    GITHUB_ENV="/tmp/github_env"
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
  assertContains "$result" "hello%20world"
}

test_urlencode_special_characters() {
  result=$(urlencode "a+b&c/d?e=f")
  assertContains "$result" "a%2Bb%26c%2Fd%3Fe%3Df"
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

  assertIntegerEquals 1 "${#SECRETS[@]}"
  assertContains "${SECRETS[0]}" "my-secret|MY_ENV"
}

test_array_secrets_multiple_secrets() {
  export INPUT_SECRETS="db/password|DB_PASS;api/key|API_KEY"
  array_secrets

  assertIntegerEquals 2 "${#SECRETS[@]}"
  assertContains "${SECRETS[0]}" "db/password|DB_PASS"
  assertContains "${SECRETS[1]}" "api/key|API_KEY"
}

test_array_secrets_no_separator() {
  export INPUT_SECRETS="plainsecret"
  array_secrets

  assertIntegerEquals 1 "${#SECRETS[@]}"
  assertContains "${SECRETS[0]}" "plainsecret"
}

test_array_secrets_empty_string() {
  export INPUT_SECRETS=""
  array_secrets

  assertIntegerEquals 0 "${#SECRETS[@]}"
}

test_array_secrets_trailing_semicolon() {
  export INPUT_SECRETS="secret1|ENV1;"
  array_secrets
  
  assertIntegerEquals 1 "${#SECRETS[@]}" 
  assertContains "${SECRETS[0]}" "secret1|ENV1"
}

# Test 'conjur_authn' function for jwt
test_conjur_authn_jwt() {

  export INPUT_AUTHN_ID="dummy-authn-id"
  export ACTIONS_ID_TOKEN_REQUEST_URL="http://github-dummy"
  export ACTIONS_ID_TOKEN_REQUEST_TOKEN="dummy-token"
  export INPUT_URL="http://dummy.conjur"
  export INPUT_ACCOUNT="dummy-account"
  export INPUT_CERTIFICATE=""

  handle_git_jwt() { echo "::debug No delta between iat [0] and epoch [0]"; }
  telemetry_header() { encoded="dummy-telemetry"; }

  curl() {
    if [[ "$*" == *"$ACTIONS_ID_TOKEN_REQUEST_URL"* ]]; then
      echo '{"value":"dummy-jwt-token"}'
    fi
  }

  result=$(conjur_authn)

  assertContains "$result" "::debug Authenticate via Authn-JWT"
}

test_conjur_authn_jwt_without_certificate() {
  export INPUT_AUTHN_ID="dummy-authn-id"
  export ACTIONS_ID_TOKEN_REQUEST_URL="http://github-dummy"
  export ACTIONS_ID_TOKEN_REQUEST_TOKEN="dummy-token"
  export INPUT_URL="http://dummy.conjur"
  export INPUT_ACCOUNT="dummy-account"
  export INPUT_CERTIFICATE=""

  handle_git_jwt() { echo "::debug No delta between iat [0] and epoch [0]"; }
  telemetry_header() { encoded="dummy-telemetry"; }

  curl() {
    if [[ "$*" == *"$ACTIONS_ID_TOKEN_REQUEST_URL"* ]]; then
      echo '{"value":"dummy-jwt-token"}'
    fi
  }

  result=$(conjur_authn)

  assertContains "$result" "::debug Authenticate via Authn-JWT"
}

# Test 'conjur_authn' function for api_key
test_conjur_authn_api_key() {
  INPUT_AUTHN_ID=""
  urlencode() {
    echo "$1"
  }
  result=$(conjur_authn)

  assertContains "$result" "::debug Authenticate using Host ID & API Key"
}

test_conjur_authn_api_key_without_certificate() {
  INPUT_AUTHN_ID=""
  INPUT_CERTIFICATE=""
  urlencode() {
    echo "$1"
  }
  result=$(conjur_authn)

  assertContains "$result" "::debug Authenticate using Host ID & API Key"
}

# Test 'set_secrets' function
test_set_secrets_empty() {
    SECRETS=""
    result=$(set_secrets)
    assertContains "::error::No secret found for retrieval from Conjur Vault" "$result"
}

test_set_secrets() {
    SECRETS="db/sqlusername|sql_username"
    result=$(set_secrets)
    assertContains "::debug Retrieving secret without certificate" "$result"
    output=$(cat $GITHUB_ENV)
    assertContains "SQL_USERNAME=fake_secret_value" "$output"
}

# Run all tests
. /usr/bin/shunit2