#!/bin/bash
# Conjur Secret Retrieval for GitHub Action conjur-action

script_dir=$(dirname "$(realpath "$0")")

# Secure temp directory — created on first use, cleaned on EXIT.
CONJUR_TMP_DIR=""

_conjur_init_tmp() {
    if [[ -z "$CONJUR_TMP_DIR" ]]; then
        CONJUR_TMP_DIR=$(mktemp -d)
        trap "rm -rf -- '$CONJUR_TMP_DIR'" EXIT
    fi
}

validate_url() {
    if [[ "$INPUT_URL" == http://* ]]; then
        if [[ "${INPUT_ALLOW_INSECURE_CONNECTIONS,,}" == "true" ]]; then
            echo "::warning::Connecting to Conjur over HTTP is insecure and not recommended for production use."
        else
            echo "::error::HTTP connections are not allowed. Use an HTTPS URL or set allow_insecure_connections: 'true' to override."
            exit 1
        fi
    fi
}

main() {
    validate_url
    create_pem
    if [[ -z "$INPUT_AUTHN_TOKEN_FILE" ]]; then
        conjur_authn
    else
        token=$(get_token_from_file)
    fi
    # Secrets Example: db/sqlusername | sql_username; db/sql_password
    array_secrets
    set_secrets
}

get_token_from_file() {
    if [[ ! -f "$INPUT_AUTHN_TOKEN_FILE" ]]; then
        echo "::error:: Conjur authn token file ${INPUT_AUTHN_TOKEN_FILE} not found on the host."
        return 1
    fi
    authn_token=$(cat "$INPUT_AUTHN_TOKEN_FILE")
    echo "$authn_token"
}

urlencode() {
    # urlencode <string>
    old_lc_collate=$LC_COLLATE
    LC_COLLATE=C

    local length="${#1}"
    for (( i = 0; i < length; i++ )); do
        local c="${1:i:1}"
        case $c in
            [a-zA-Z0-9.~_-]) printf "$c" ;;
            ' ') printf "%%20" ;;
            *) printf '%%%02X' "'$c" ;;
        esac
    done

    LC_COLLATE=$old_lc_collate
}

create_pem() {
    # Write the CA cert under a private, process-owned temp dir (mktemp -d creates 0700)
    _conjur_init_tmp
    local old_umask
    old_umask=$(umask)
    umask 077
    echo "$INPUT_CERTIFICATE" > "$CONJUR_TMP_DIR/conjur_${INPUT_ACCOUNT}.pem"
    umask "$old_umask"
}

create_client_cert_files() {
    _conjur_init_tmp
    local old_umask
    old_umask=$(umask)
    umask 077
    printf '%s' "$INPUT_CLIENT_CERT" > "$CONJUR_TMP_DIR/client.crt"
    printf '%s' "$INPUT_CLIENT_KEY" > "$CONJUR_TMP_DIR/client.key"
    umask "$old_umask"
}

conjur_curl() {
    local cert_args=()
    if [[ -n "$INPUT_CERTIFICATE" ]]; then
        cert_args=(--cacert "$CONJUR_TMP_DIR/conjur_$INPUT_ACCOUNT.pem")
    fi

    # Enforce HTTPS unless the caller has explicitly opted into HTTP via
    # allow_insecure_connections and the URL is actually http://.
    local tls_args=()
    if [[ "${INPUT_URL,,}" != http://* || "${INPUT_ALLOW_INSECURE_CONNECTIONS,,}" != "true" ]]; then
        tls_args=(--proto '=https' --proto-redir '=https' --ssl-reqd)
    fi

    local response rc
    response=$(curl -sS --show-error --write-out $'\n%{http_code}' "${cert_args[@]}" "${tls_args[@]}" "$@")
    rc=$?

    if (( rc != 0 )); then
        http_status=""
        http_body="$response"
        return $rc
    fi

    http_status=${response##*$'\n'}
    http_body=${response%$'\n'*}
    return 0
}

debug_cert_mode() {
    local context=$1
    if [[ -n "$INPUT_CERTIFICATE" ]]; then
        echo "::debug ${context} with certificate"
    else
        echo "::debug ${context} without certificate"
    fi
}

handle_git_jwt() {
    ## Handle JWT Token epoch time sync

    # Grab JWT Token
    local jwt_token=$1
    # Parse payload body
    j_body=$( echo "$jwt_token" | cut -d "." -f 2 )
    # Repad b64 token (dirty)
    padd="=="
    jwt_padded="${j_body}${padd}"
    #decode payload body
    payload=$(echo "$jwt_padded" | base64 -d)
    # capture IAT time
    iat=$( echo "$payload" | jq .iat )

    # Check if IAT less than or equal to server epoch
    if (( "$iat" <= "$EPOCHSECONDS" )); then

        echo "::debug No delta between iat [$iat] and epoch [$EPOCHSECONDS]"

    # check if IAT greater than server epoch, if so, calculate delta and sleep before returning
    elif (( "$iat" > "$EPOCHSECONDS" )); then

        delta=$(( "$iat" - "$EPOCHSECONDS" ))
        echo "::debug delta found: iat [$iat] // epoch [$EPOCHSECONDS]; sleeping for $delta seconds"
        sleep "$delta"

    else
        echo "::debug unhandled problem"
        exit 1
    fi
    ####
}

telemetry_header(){
    changelog_file="$script_dir/CHANGELOG.md"
    if [ -f "$changelog_file" ]; then
        get_version=$(grep -o '\[[0-9]\+\.[0-9]\+\.[0-9]\+\]' $changelog_file | head -n 1 | tr -d '[]')
    else
        get_version="0.0.0-default"
    fi
    telemetry_val="in=Github Actions&it=cybr-secretsmanager&iv=$get_version&vn=Github"
    encoded=$(echo -n "$telemetry_val" | base64 | tr '+/' '-_' | tr -d '=' | tr -d '[:space:]')
}

conjur_authn() {
    telemetry_header
	if [[ -n "$INPUT_AUTHN_ID" ]]; then

		echo "::debug Authenticate via Authn-JWT"

        local token_url="$ACTIONS_ID_TOKEN_REQUEST_URL"
        if [[ -n "$INPUT_AUDIENCE" ]]; then
            echo "::debug Adding custom audience"
            token_url="${token_url}&audience=$(urlencode "${INPUT_AUDIENCE}")"
        fi
        
        JWT_TOKEN=$(printf 'header = "Authorization: bearer %s"\n' "$ACTIONS_ID_TOKEN_REQUEST_TOKEN" | \
            curl -s --config - "$token_url" | jq -r .value)
        handle_git_jwt "$JWT_TOKEN"

        REST_API_BASE_URI="${INPUT_URL}/authn-jwt/${INPUT_AUTHN_ID}/${INPUT_ACCOUNT}/authenticate"

        if [[ -n "$INPUT_HOST_ID" ]]; then
            echo "::debug Authenticate using Host ID"
            hostId=$(urlencode "$INPUT_HOST_ID")
            REST_API_BASE_URI="${INPUT_URL}/authn-jwt/${INPUT_AUTHN_ID}/${INPUT_ACCOUNT}/${hostId}/authenticate"
        fi
        
        debug_cert_mode "Authenticating"
        local _jwt_body
        _jwt_body="jwt=$(urlencode "$JWT_TOKEN")"
        conjur_curl --request POST "$REST_API_BASE_URI" \
                --header "Content-Type: application/x-www-form-urlencoded" \
                --header "x-cybr-telemetry: $encoded" \
                --header "Accept-Encoding: base64" \
                --data-binary @- < <(printf '%s' "$_jwt_body") || {
            local rc=$?
            echo "::error::Conjur authentication request failed (curl exit $rc)"
            exit 1
        }
        if [[ "$http_status" != "200" ]]; then
            echo "::error::Conjur authentication failed (HTTP $http_status): $http_body"
            exit 1
        fi
        token="${http_body//$'\n'/}"
    elif [[ -n "$INPUT_AUTHN_CERT_ID" ]]; then
        echo "::debug Authenticate via Authn-Cert"

        if [[ -z "$INPUT_CLIENT_CERT" ]]; then
            echo "::error::client_cert is required for certificate authentication"
            exit 1
        fi
        if [[ -z "$INPUT_CLIENT_KEY" ]]; then
            echo "::error::client_key is required for certificate authentication"
            exit 1
        fi

        create_client_cert_files

        # host_id is required for request host-mode (default), but optional for
        # SPIFFE host-mode (self-hosted) where the workload is derived from the
        # certificate's SPIFFE ID — same optional pattern as authn-jwt.
        local REST_API_BASE_URI="${INPUT_URL}/authn-cert/${INPUT_AUTHN_CERT_ID}/${INPUT_ACCOUNT}/authenticate"
        if [[ -n "$INPUT_HOST_ID" ]]; then
            echo "::debug Authenticate using Host ID"
            local workloadId
            workloadId=$(urlencode "$INPUT_HOST_ID")
            REST_API_BASE_URI="${INPUT_URL}/authn-cert/${INPUT_AUTHN_CERT_ID}/${INPUT_ACCOUNT}/${workloadId}/authenticate"
        fi

        debug_cert_mode "Authenticating"
        conjur_curl --request POST "$REST_API_BASE_URI" \
                --cert "$CONJUR_TMP_DIR/client.crt" \
                --key "$CONJUR_TMP_DIR/client.key" \
                --header "Accept-Encoding: base64" \
                --header "x-cybr-telemetry: $encoded" || {
            local rc=$?
            echo "::error::Conjur authentication request failed (curl exit $rc)"
            exit 1
        }
        if [[ "$http_status" != "200" ]]; then
            echo "::error::Conjur authentication failed (HTTP $http_status): $http_body"
            exit 1
        fi
        token="${http_body//$'\n'/}"
	else
        echo "::debug Authenticate using Host ID & API Key"

        # URL-encode Host ID for future use
        hostId=$(urlencode "$INPUT_HOST_ID")

        debug_cert_mode "Authenticating"
        conjur_curl --request POST \
                "$INPUT_URL/authn/$INPUT_ACCOUNT/$hostId/authenticate" \
                --header "Content-Type: application/x-www-form-urlencoded" \
                --header "x-cybr-telemetry: $encoded" \
                --header "Accept-Encoding: base64" \
                --data-binary @- < <(printf '%s' "$INPUT_API_KEY") || {
            local rc=$?
            echo "::error::Conjur authentication request failed (curl exit $rc)"
            exit 1
        }
        if [[ "$http_status" != "200" ]]; then
            echo "::error::Conjur authentication failed (HTTP $http_status): $http_body"
            exit 1
        fi
        token="${http_body//$'\n'/}"
    fi
}

array_secrets() {
    local IFS=';'
    read -ra SECRETS <<< "$INPUT_SECRETS" # [0]=db/sqlusername | sql_username [1]=db/sql_password
}

set_secrets() {
    if [[ ${SECRETS[@]} ]]; then
        telemetry_header
        for secret in "${SECRETS[@]}"; do
            local IFS='|'
            read -ra METADATA <<< "$secret" # [0]=db/sqlusername [1]=sql_username

            if [[ "${#METADATA[@]}" == 2 ]]; then
                secretId=$(urlencode "${METADATA[0]}")
                envVar=${METADATA[1]^^}
            else
                secretId=${METADATA[0]}
                local IFS='/'
                read -ra SPLITSECRET <<< "$secretId" # [0]=db [1]=sql_password
                arrLength=${#SPLITSECRET[@]} # Get array length
                lastIndex=$((arrLength-1)) # Subtract one for last index
                envVar=${SPLITSECRET[$lastIndex]^^}
                secretId=$(urlencode "${METADATA[0]}")
            fi

            debug_cert_mode "Retrieving secret"
            local _auth_hdr="${CONJUR_TMP_DIR}/.auth_header"
            printf 'Authorization: Token token="%s"' "$token" > "$_auth_hdr"
            conjur_curl --header "@${_auth_hdr}" \
                    --header "x-cybr-telemetry: $encoded" \
                    "$INPUT_URL/secrets/$INPUT_ACCOUNT/variable/$secretId" || {
                local rc=$?
                rm -f "$_auth_hdr"
                echo "::error::Secret retrieval request failed (curl exit $rc)"
                exit 1
            }
            rm -f "$_auth_hdr"
            secretVal=$http_body
            if [[ "$http_status" != "200" ]]; then
                echo "::error::Failed to retrieve secret '$secretId' (HTTP $http_status)."
                exit 1
            fi

            if [[ "${secretVal}" == "Malformed authorization token" ]]; then
                echo "::error::Malformed authorization token. Please check your Conjur account, username, and API key. If using authn-jwt, check your Host ID annotations are correct."
                exit 1
            elif [[ "${secretVal}" == *"is empty or not found"* ]]; then
                echo "::error::${secretVal}"
                exit 1
            fi
            if [[ "${envVar}" =~ $'\n' || "${envVar}" == *"<<"* || "${envVar}" == *"="* || -z "${envVar}" ]]; then                                                                                    
                echo "::error::Invalid environment variable name '${envVar}'; refusing to write."                                                                             
                exit 1                                                                                                                                                        
            fi
            local _delim="EOF_$RANDOM$RANDOM$RANDOM"
            if [[ "${secretVal}" == *"${_delim}"* ]]; then
                echo "::error::Secret value contains env delimiter; refusing to write."
                exit 1
            fi
            
            while IFS= read -r _maskLine; do
                [[ -n "${_maskLine}" ]] && echo "::add-mask::${_maskLine}"
            done <<< "${secretVal}"
            {
                echo "${envVar}<<${_delim}"
                echo "${secretVal}"
                echo "${_delim}"
            } >> "${GITHUB_ENV}"
        done
    else
        echo "::error::No secret found for retrieval from Conjur Vault"
    fi
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi