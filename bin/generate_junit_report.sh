#!/bin/bash

test_output=$(./test/entrypoint_test.sh)

tests_passed=$(echo "$test_output" | grep -c "OK")
tests_failed=$(echo "$test_output" | grep -c "FAILED")

cat <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<testsuite name="BashUnitTests" tests="$(($tests_passed + $tests_failed))" failures="$tests_failed" errors="0" skipped="0">
EOF

for test in $(echo "$test_output" | grep -oP 'test_\w+'); do
  status="pass"
  
  if echo "$test_output" | grep -q "$test.*FAILED"; then
    status="fail"
  fi

  cat <<EOF
  <testcase classname="BashUnitTests" name="$test" time="0">
    $(if [[ "$status" == "fail" ]]; then echo "<failure message='Test Failed'/>"; fi)
  </testcase>
EOF
done

echo "</testsuite>"
