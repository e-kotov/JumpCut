#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
test_binary="$(mktemp -t jumpcut-payload-tests)"
trap 'rm -f "$test_binary"' EXIT
clang -Wall -Wextra -Werror -fsanitize=undefined \
  Tests/IOHIDPayloadTests.c Sources/CStrafe/IOHIDPayload.c Sources/CStrafe/CStrafe.c \
  -I Sources/CStrafe -I Sources/CStrafe/include \
  -framework ApplicationServices -framework CoreGraphics -framework CoreFoundation \
  -o "$test_binary"
"$test_binary"
