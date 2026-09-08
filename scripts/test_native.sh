#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build
xcrun swiftc -swift-version 5 -module-cache-path build/swift-cache native/Core.swift native/Runtime.swift native/AppSettings.swift native/CoreTests.swift -o build/native-tests
./build/native-tests
