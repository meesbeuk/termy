#!/bin/zsh
# Run the Termy test suite. Re-applies the SwiftTerm source patches first
# (swift package operations can blow away .build/checkouts), then runs
# `swift test`. The patches are load-bearing for the input/caret tests.
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$PROJECT_DIR"

if [[ ! -d "$PROJECT_DIR/.build/checkouts/SwiftTerm" ]]; then
    swift package resolve
fi
"$PROJECT_DIR/release_helpers/patch-swiftterm.sh"

echo "── Running tests ──"
# This box has Command Line Tools only (no Xcode.app), so XCTest.framework is
# absent. Swift Testing ships with the toolchain — disable the XCTest bundle so
# `swift test` builds the swift-testing runner instead of failing to link XCTest.
#
# CLT doesn't put Testing.framework or its private lib_TestingInterop.dylib on
# the default search paths, so wire them up explicitly:
#   FWK  — Testing.swiftmodule + Testing.framework (compile + link + rpath)
#   LIB  — lib_TestingInterop.dylib that Testing.framework dlopens at runtime
FWK="/Library/Developer/CommandLineTools/Library/Developer/Frameworks"
LIB="/Library/Developer/CommandLineTools/Library/Developer/usr/lib"
swift test --disable-xctest --enable-swift-testing \
    -Xswiftc -F -Xswiftc "$FWK" \
    -Xlinker -F -Xlinker "$FWK" \
    -Xlinker -rpath -Xlinker "$FWK" \
    -Xlinker -rpath -Xlinker "$LIB" \
    "$@"
