#!/bin/bash
# Runs the Swift Testing suites on a machine with only the Command Line Tools
# (no Xcode.app). With full Xcode installed, plain `swift test` works and this
# script isn't needed.
#
# Two toolchain problems are worked around here, both confirmed on a trivial
# standalone package (so they're the toolchain's, not this project's):
#
#  1. Build: swift-build hands the compiler `-plugin-path .../plugins/testing`
#     but the compiler never ends up loading libTestingMacros.dylib, so every
#     `@Test` / `#expect` fails with "plugin for module 'TestingMacros' not
#     found". Loading the library explicitly with `-load-plugin-library` works.
#
#  2. Run: the test bundle can't find Testing.framework / lib_TestingInterop at
#     runtime (they live in directories the dynamic loader doesn't search).
#     DYLD_* is set ONLY while running the already-built bundles — setting it
#     during the build corrupts the build.
set -euo pipefail
cd "$(dirname "$0")/.."

CLT=/Library/Developer/CommandLineTools
PLUGIN="$CLT/usr/lib/swift/host/plugins/testing/libTestingMacros.dylib"
HELPER="$CLT/usr/libexec/swift/pm/swiftpm-testing-helper"

[ -f "$PLUGIN" ] || { echo "missing $PLUGIN — is the Command Line Tools install complete?" >&2; exit 1; }

swift build --build-tests -Xswiftc -load-plugin-library -Xswiftc "$PLUGIN"

BIN_DIR=$(swift build --show-bin-path)
FILTER="${1:-}"
status=0
ran=0

for bundle in "$BIN_DIR"/*.xctest; do
  name=$(basename "$bundle" .xctest)
  if [ -n "$FILTER" ] && [[ "$name" != *"$FILTER"* ]]; then continue; fi
  bin="$bundle/Contents/MacOS/$name"
  echo "==> $name"
  ran=$((ran + 1))
  DYLD_FRAMEWORK_PATH="$CLT/Library/Developer/Frameworks" \
  DYLD_LIBRARY_PATH="$CLT/Library/Developer/usr/lib" \
    "$HELPER" --test-bundle-path "$bin" "$bin" --testing-library swift-testing || status=1
done

[ "$ran" -gt 0 ] || { echo "no test bundles matched '$FILTER'" >&2; exit 1; }
exit $status
