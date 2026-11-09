#!/bin/bash
# Runs the Swift test suite. With only Xcode's Command Line Tools installed
# (no full Xcode), SwiftPM can't find the Swift Testing framework on its
# own, so point it there.
set -euo pipefail
cd "$(dirname "$0")"
CLT="$(xcode-select -p)"
FRAMEWORKS="$CLT/Library/Developer/Frameworks"
LIBS="$CLT/Library/Developer/usr/lib"
exec swift test \
    -Xswiftc -F -Xswiftc "$FRAMEWORKS" \
    -Xlinker -F -Xlinker "$FRAMEWORKS" \
    -Xlinker -rpath -Xlinker "$FRAMEWORKS" \
    -Xlinker -rpath -Xlinker "$LIBS" \
    "$@"
