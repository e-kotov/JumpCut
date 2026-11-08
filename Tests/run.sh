#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
test_dir="$(mktemp -d -t jumpcut-c-tests)"
trap 'rm -rf "$test_dir"' EXIT
flags=(-Wall -Wextra -Werror -fsanitize=undefined
  -I Sources/CStrafe -I Sources/CStrafe/include
  -framework ApplicationServices -framework CoreGraphics -framework CoreFoundation)
sources=(Sources/CStrafe/IOHIDPayload.c Sources/CStrafe/CStrafe.c)

clang "${flags[@]}" Tests/IOHIDPayloadTests.c "${sources[@]}" -o "$test_dir/payload"
"$test_dir/payload"

clang "${flags[@]}" -DJUMPCUT_TESTING -DJUMPCUT_PREPARATION_TESTING \
  Tests/GesturePreparationTests.c "${sources[@]}" -o "$test_dir/preparation"
"$test_dir/preparation"

clang "${flags[@]}" -DJUMPCUT_TESTING \
  Tests/TopologyTests.c "${sources[@]}" -o "$test_dir/topology"
"$test_dir/topology"
