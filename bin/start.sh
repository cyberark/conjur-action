#!/bin/bash
set -ex

declare -x DOCKER_NETWORK=''

declare -x ENTERPRISE='false'
declare -x CLOUD='false'
declare -x EDGE='false'
declare -x API_KEY=''
declare -x ADMIN_API_KEY=''

source "$(git rev-parse --show-toplevel)/bin/util.sh"

function help {
  cat <<EOF
Conjur Action :: Dev Environment

$0 [options]

-e            Deploy Conjur Enterprise. (Default: Conjur Open Source)
-c            Deploy Conjur Cloud. (Developers should not use this option to start a local environment.)
-h, --help    Print usage information.
EOF
}

while true ; do
  case "$1" in
    -e ) ENTERPRISE="true" ; shift ;;
    -c )  
      if [[ "$OSTYPE" == "darwin"* ]]; then
        echo "Cannot setup a local environment using Conjur Cloud"
        exit 1
      fi
      CLOUD="true"
      shift ;;
    -ed )  
      if [[ "$OSTYPE" == "darwin"* ]]; then
        echo "Cannot setup a local environment using Conjur Edge"
        exit 1
      fi
      EDGE="true"
      shift ;;
    -h | --help ) help && exit 0 ;;
    * )
      if [[ -z "$1" ]]; then
        break
      else
        echo "$1 is not a valid option"
        help
        exit 1
      fi ;;
  esac
done

function clean {
  cd "$(bin_dir)"
  ./stop.sh
}
trap clean ERR

function setup_conjur_resources {
  echo "---- setting up Conjur resources ----"

  policy_path="root.yml"
  if [[ "$ENTERPRISE" == "false" ]]; then
    policy_path="/policy/$policy_path"
  fi

  docker exec "$(cli_cid)" /bin/sh -c "
    conjur policy load -b root -f $policy_path
    conjur variable set -i github-app/Dev-Team-credential1 -v test_dev_1
    conjur variable set -i github-app/Dev-Team-credential2 -v test_dev_2
  "
}

function deploy_conjur_open_source() {
  echo "---- deploying Conjur Open Source ----"

  # start conjur server
  docker compose up -d --build conjur conjur-proxy-nginx
  set_conjur_cid "$(docker compose ps -q conjur)"
  wait_for_conjur

  # get admin credentials
  fetch_conjur_cert "$(docker compose ps -q conjur-proxy-nginx)" "cert.crt"
  ADMIN_API_KEY="$(user_api_key "$CONJUR_ACCOUNT" admin)"

  # start conjur cli and configure conjur
  docker compose up --no-deps -d conjur_cli
  set_cli_cid "$(docker compose ps -q conjur_cli)"
  setup_conjur_resources
}

function deploy_conjur_enterprise {
  echo "---- deploying Conjur Enterprise ----"

  ensure_submodules

  pushd ./conjur-intro
    # start conjur leader and follower
    ./bin/dap --provision-master
    ./bin/dap --provision-follower
    set_conjur_cid "$(docker compose ps -q conjur-master.mycompany.local)"

    fetch_conjur_cert "$(conjur_cid)" "/etc/ssl/certs/ca.pem"

    # Run 'sleep infinity' in the CLI container so it stays alive
    set_cli_cid "$(docker compose run --no-deps -d -w /src/cli --entrypoint sleep client infinity)"
    # Authenticate the CLI container
    docker exec "$(cli_cid)" /bin/sh -c "
      if [ ! -e /root/conjur-demo.pem ]; then
        echo y | conjur init -u ${CONJUR_APPLIANCE_URL} -a ${CONJUR_ACCOUNT} --force --self-signed
      fi
      conjur login -i admin -p MySecretP@ss1
    "
    # configure conjur
    cp ../policy/root.yml . && setup_conjur_resources
  popd
}

# deploy conjur cloud
function url_encode() {
  printf '%s' "$1" | jq -sRr @uri
}

function set_conjur_cloud_variable() {
  local variable_name="$1"
  local data="$2"
  local encoded_variable_name
  encoded_variable_name=$(url_encode "$variable_name")
  curl -w "%{http_code}" -H "Authorization: Token token=\"$INFRAPOOL_CONJUR_AUTHN_TOKEN\"" \
       -X POST --data-urlencode "${data}" "${CONJUR_APPLIANCE_URL}/secrets/conjur/variable/${encoded_variable_name}"
}

function deploy_conjur_cloud() {
  curl -w "%{http_code}" -H "Authorization: Token token=\"$INFRAPOOL_CONJUR_AUTHN_TOKEN\"" \
       -X POST -d "$(cat ./policy/root.yml)" "${CONJUR_APPLIANCE_URL}/policies/conjur/policy/data"

  set_conjur_cloud_variable "data/github-app/Dev-Team-credential1" "test_dev_1"
  set_conjur_cloud_variable "data/github-app/Dev-Team-credential2" "test_dev_2"
}

function main() {
  # remove previous environment
  clean
  mkdir -p tmp

  if [[ "$ENTERPRISE" == "true" ]]; then
    export CONJUR_APPLIANCE_URL='https://conjur-master.mycompany.local'
    export CONJUR_ACCOUNT='demo'
    export CONJUR_AUTHN_LOGIN='admin'
    export DOCKER_NETWORK='dap_net'
    make_network $DOCKER_NETWORK
    # start conjur enterprise leader and follower
    deploy_conjur_enterprise
    export ADMIN_API_KEY=$(rotate_api_key)
    export CONJUR_SSL_CERTIFICATE=$(cat $(bin_dir)/conjur.pem)
    export CONJUR_SECRET="github-app/Dev-Team-credential1"

  elif [[ "$CLOUD" == "true" ]]; then
    #disable the debugging
    set +x
    export CONJUR_APPLIANCE_URL="$INFRAPOOL_CONJUR_APPLIANCE_URL/api"
    export CONJUR_ACCOUNT=conjur
    export CONJUR_AUTHN_LOGIN=$INFRAPOOL_CONJUR_AUTHN_LOGIN
    echo "$INFRAPOOL_CONJUR_AUTHN_TOKEN" > "$(bin_dir)/access_token"
    export CONJUR_AUTHN_TOKEN_FILE="/conjur-action/bin/access_token"
    export CONJUR_SSL_CERTIFICATE=$(cat $(bin_dir)/cloud_ca.pem)
    export CONJUR_SECRET="data/github-app/Dev-Team-credential1"
    export DOCKER_NETWORK='conjur_action'
    make_network $DOCKER_NETWORK
    #upload the policy into cloud tenant pool
    deploy_conjur_cloud
    #Enable the debugging
    set -x
  elif [[ "$EDGE" == "true" ]]; then
    #disable the debugging
    set +x
    export CONJUR_APPLIANCE_URL="https://edge-test:8443/api"
    export CONJUR_ACCOUNT=conjur
    export CONJUR_AUTHN_LOGIN=$INFRAPOOL_CONJUR_AUTHN_LOGIN
    echo "$INFRAPOOL_CONJUR_AUTHN_TOKEN" > "$(bin_dir)/access_token"
    export CONJUR_AUTHN_TOKEN_FILE="/conjur-action/bin/access_token"
    export CONJUR_SECRET="data/github-app/Dev-Team-credential1"
    export DOCKER_NETWORK='conjur_action'
    make_network $DOCKER_NETWORK
    openssl s_client -connect localhost:443 -showcerts </dev/null 2>/dev/null | openssl x509 -outform PEM > "$(bin_dir)/conjur.pem"
    export CONJUR_SSL_CERTIFICATE=$(cat $(bin_dir)/conjur.pem)
    # Adding edge to the docker network
    docker network inspect $DOCKER_NETWORK --format '{{json .Containers}}' | grep -q 'edge-test' || docker network connect $DOCKER_NETWORK edge-test
    #Enable the debugging
    set -x
  else
    export CONJUR_APPLIANCE_URL='https://conjur-proxy-nginx'
    export CONJUR_ACCOUNT='cucumber'
    export CONJUR_AUTHN_LOGIN='admin'
    export DOCKER_NETWORK='conjur_action'
    make_network $DOCKER_NETWORK
    # start conjur server and proxy
    deploy_conjur_open_source
    export CONJUR_SSL_CERTIFICATE=$(cat $(bin_dir)/conjur.pem)
    export ADMIN_API_KEY=$ADMIN_API_KEY
    export CONJUR_SECRET="github-app/Dev-Team-credential1"
  fi

   cat <<EOF > $(git rev-parse --show-toplevel)/.github/workflows/.secrets
URL="$CONJUR_APPLIANCE_URL"
ACCOUNT="$CONJUR_ACCOUNT"
HOST_ID="$CONJUR_AUTHN_LOGIN"
API_KEY="$ADMIN_API_KEY"
AUTHN_TOKEN_FILE="$CONJUR_AUTHN_TOKEN_FILE"
SECRET="$CONJUR_SECRET"
SECRET_VALUE="test_dev_1"
CERTIFICATE="$CONJUR_SSL_CERTIFICATE"
EOF
  if [[ "$ENTERPRISE" == "true" ]]; then
    docker compose -f docker-compose.enterpise.yml up -d --build act
    docker compose -f docker-compose.enterpise.yml exec -T act bash -c "cp /conjur-action/bin/main.yml /conjur-action/.github/workflows"
    docker compose -f docker-compose.enterpise.yml exec -T act bash -c "act --network $DOCKER_NETWORK -P node:16-buster-slim --secret-file=./.github/workflows/.secrets push"
  else
    docker compose up -d --build act
    docker compose exec -T act bash -c "cp /conjur-action/bin/main.yml /conjur-action/.github/workflows"
    docker compose exec -T act bash -c "act --network $DOCKER_NETWORK -P node:16-buster-slim --secret-file=./.github/workflows/.secrets push"
  fi
}

main
