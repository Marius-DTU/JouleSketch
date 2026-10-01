#!/bin/sh
# Builds the web (Windows) version of JouleSketch into Web/app/dist.
#
#   Web/build.sh          builds the finished site
#   Web/build.sh dev      builds the Swift part and starts a local test server
#
# Needs the Swift toolchain from swift.org with the WebAssembly SDK, and
# Node.js (see Web/README.md).
set -e

cd "$(dirname "$0")/.."
SDK="${SWIFT_SDK:-swift-6.4.0-RELEASE_wasm}"

# The shared Swift code, compiled to WebAssembly, goes to Web/app/core.
swift package --swift-sdk "$SDK" --allow-writing-to-package-directory js -c release --product JouleWeb --output Web/app/core

cd Web/app
npm install --no-audit --no-fund
if [ "$1" = "dev" ]; then
  npm run dev
else
  npm run build
  echo "Færdig: Web/app/dist"
fi
