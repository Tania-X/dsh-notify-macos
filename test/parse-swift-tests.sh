#!/bin/bash
# Syntax-check the XCTest sources without needing XCTest itself
# (Command Line Tools cannot resolve XCTest; `swiftc -parse` only parses).
# Catches structural mistakes (e.g. stray braces) before CI compiles them.
set -u
fail=0
for f in Tests/dshNotifyCoreTests/*.swift; do
  if out=$(swiftc -parse "$f" 2>&1) && ! grep -q 'error:' <<<"$out"; then
    echo "PARSE OK: $f"
  else
    echo "PARSE FAIL: $f"
    grep 'error:' <<<"$out" | head -5
    fail=1
  fi
done
exit $fail
