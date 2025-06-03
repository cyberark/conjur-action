#!/usr/bin/env bash
set -euo pipefail

OUTPUT_DIR="./output"

mkdir -p "$OUTPUT_DIR"

[ -f /etc/apt/sources.list ] && cp -f /etc/apt/sources.list .

docker build -f Dockerfile.test -t unit-test .

docker run --rm \
  -v "$OUTPUT_DIR:/conjur-action/coverage" \
  unit-test \
  bash -c "\
    bashcov --root . -- test/entrypoint_test.sh && \
    ruby -r '/conjur-action/test/test_helper.rb' && \
    ./bin/generate_junit_report.sh > /conjur-action/coverage/junit.xml"
