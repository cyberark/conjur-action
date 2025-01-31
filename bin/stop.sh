#!/bin/bash
set -ex
source "$(git rev-parse --show-toplevel)/bin/util.sh"

declare -x DOCKER_NETWORK='conjur_action'

echo "---- removing local environment----"
cd "$(bin_dir)"

docker compose down -v

if [[ -n "$(cli_cid)" ]]; then
  docker rm -f "$(cli_cid)" 2>/dev/null
fi

if [ -d "conjur-intro" ] && [ "$(ls -A conjur-intro)" ]; then
  pushd conjur-intro > /dev/null
    ./bin/dap --stop
  popd > /dev/null
fi

clean_submodules

rm -rf conjur.pem access_token
