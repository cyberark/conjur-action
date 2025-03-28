#!/bin/bash

function bin_dir {
  repo="$(git rev-parse --show-superproject-working-tree)"
  if [[ "$repo" == "" ]]; then
    repo="$(git rev-parse --show-toplevel)"
  fi

  echo "$repo/bin"
}

function make_network(){
  local name="$1"
  if [ ! -z $(docker network inspect "$name" > /dev/null || echo $?) ]; then
    docker network create "$name"
  fi
}

function set_cli_cid {
  echo "$1" > "$(bin_dir)/tmp/cli_cid"
}

function cli_cid {
  cat "$(bin_dir)/tmp/cli_cid"
}

function set_conjur_cid {
  echo "$1" > "$(bin_dir)/tmp/conjur_cid"
}

function conjur_cid {
  cat "$(bin_dir)/tmp/conjur_cid"
}

function fetch_conjur_cert {
  local cid="$1"
  local cert_path="$2"

  (docker exec "$cid" cat "$cert_path") > "$(bin_dir)/conjur.pem"
}

function wait_for_conjur {
  docker exec "$(conjur_cid)" conjurctl wait -p 3000
}

function user_api_key {
  local account="$1"
  local id="$2"
  docker exec "$(conjur_cid)" conjurctl role retrieve-key "$account:user:$id"
}

function rotate_api_key {
 docker exec "$(cli_cid)" conjur user rotate-api-key
}

function ensure_submodules {
  if [ -d "$(bin_dir)/conjur-intro" ]; then
   rm -rf "$(bin_dir)/conjur-intro"
   git clone https://github.com/conjurdemos/conjur-intro.git
   #git submodule init -- "$(bin_dir)/conjur-intro"
   #git submodule update --remote -- "$(bin_dir)/conjur-intro"
  fi
}

function clean_submodules {
  if [ -d "$(bin_dir)/conjur-intro" ]; then
    pushd "$(bin_dir)/conjur-intro"
      git clean -df
    popd
  fi
}
