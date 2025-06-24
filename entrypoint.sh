#!/bin/bash
# Conjur Secret Retrieval for GitHub Action conjur-action

script_dir=$(dirname "$(realpath "$0")")

main() {
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
    # Create conjur_account.pem for valid SSL
    echo "$INPUT_CERTIFICATE" > conjur_"$INPUT_ACCOUNT".pem
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
        JWT_TOKEN=$( curl -s -H "Authorization:bearer $ACTIONS_ID_TOKEN_REQUEST_TOKEN" "$ACTIONS_ID_TOKEN_REQUEST_URL" | jq -r .value )
        handle_git_jwt "$JWT_TOKEN"
        
		if [[ -n "$INPUT_CERTIFICATE" ]]; then
            echo "::debug Authenticating with certificate"
			token=$(curl --cacert "conjur_$INPUT_ACCOUNT.pem" --request POST "$INPUT_URL/authn-jwt/$INPUT_AUTHN_ID/$INPUT_ACCOUNT/authenticate" --header "Content-Type: application/x-www-form-urlencoded" --header "x-cybr-telemetry: $encoded" --header "Accept-Encoding: base64" --data-urlencode "jwt=$JWT_TOKEN")
		else
            echo "::debug Authenticating without certificate"
			token=$(curl --request POST "$INPUT_URL/authn-jwt/$INPUT_AUTHN_ID/$INPUT_ACCOUNT/authenticate" --header 'Content-Type: application/x-www-form-urlencoded' --header "x-cybr-telemetry: $encoded" --header "Accept-Encoding: base64" --data-urlencode "jwt=$JWT_TOKEN")
		fi

	else
		echo "::debug Authenticate using Host ID & API Key"

        # URL-encode Host ID for future use
        hostId=$(urlencode "$INPUT_HOST_ID")

		if [[ -n "$INPUT_CERTIFICATE" ]]; then
			# Authenticate and receive session token from Conjur - encode Base64
			echo "::debug Authenticating with certificate"
            token=$(curl --cacert "conjur_$INPUT_ACCOUNT.pem" --data "$INPUT_API_KEY" "$INPUT_URL/authn/$INPUT_ACCOUNT/$hostId/authenticate" --header "Content-Type: application/x-www-form-urlencoded"  --header "x-cybr-telemetry: $encoded" --header "Accept-Encoding: base64")
		else
			# Authenticate and receive session token from Conjur - encode Base64
            echo "::debug Authenticating without certificate"
			token=$(curl --request POST --data "$INPUT_API_KEY" "$INPUT_URL/authn/$INPUT_ACCOUNT/$hostId/authenticate" --header "Content-Type: application/x-www-form-urlencoded" --header "x-cybr-telemetry: $encoded" --header "Accept-Encoding: base64")
		fi
	fi
}

array_secrets() {
    IFS=';'
    read -ra SECRETS <<< "$INPUT_SECRETS" # [0]=db/sqlusername | sql_username [1]=db/sql_password
}

set_secrets() {
  if [[ ${SECRETS[@]} ]]; then
    telemetry_header
    for secret in "${SECRETS[@]}"; do
        IFS='|'
        read -ra METADATA <<< "$secret" # [0]=db/sqlusername [1]=sql_username

        if [[ "${#METADATA[@]}" == 2 ]]; then
            secretId=$(urlencode "${METADATA[0]}")
            envVar=${METADATA[1]^^}
        else
            secretId=${METADATA[0]}
            IFS='/'
            read -ra SPLITSECRET <<< "$secretId" # [0]=db [1]=sql_password
            arrLength=${#SPLITSECRET[@]} # Get array length
            lastIndex=$((arrLength-1)) # Subtract one for last index
            envVar=${SPLITSECRET[$lastIndex]^^}
            secretId=$(urlencode "${METADATA[0]}")
        fi
        
        if [[ -n "$INPUT_CERTIFICATE" ]]; then
            echo "::debug Retrieving secret with certificate"
            secretVal=$(curl --cacert "conjur_$INPUT_ACCOUNT.pem" -H "Authorization: Token token=\"$token\"" --header "x-cybr-telemetry: $encoded" "$INPUT_URL/secrets/$INPUT_ACCOUNT/variable/$secretId")
        else
            echo "::debug Retrieving secret without certificate"
            secretVal=$(curl -H "Authorization: Token token=\"$token\"" --header "x-cybr-telemetry: $encoded" "$INPUT_URL/secrets/$INPUT_ACCOUNT/variable/$secretId")
        fi

        if [[ "${secretVal}" == "Malformed authorization token" ]]; then
            echo "::error::Malformed authorization token. Please check your Conjur account, username, and API key. If using authn-jwt, check your Host ID annotations are correct."
            exit 1
	elif [[ "${secretVal}" == *"is empty or not found"* ]]; then
	    echo "::error::${secretVal}"
	    exit 1
        fi
        echo ::add-mask::"${secretVal}" # Masks the value in all logs & output
        echo "${envVar}=${secretVal}" >> "${GITHUB_ENV}" # Set environment variable
    done
  else 
   echo "::error::No secret found for retrieval from Conjur Vault"
  fi
}

main "$@"
