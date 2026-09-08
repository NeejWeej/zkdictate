#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build
xcrun swiftc -swift-version 5 -module-cache-path build/swift-cache native/Core.swift native/Runtime.swift native/AppSettings.swift native/CoreTests.swift -o build/native-tests
./build/native-tests

xcrun swiftc -swift-version 5 -module-cache-path build/swift-cache native/Core.swift native/Runtime.swift native/AppSettings.swift native/Clipboard.swift native/ClipboardPanel.swift native/ClipboardTests.swift -framework AppKit -o build/clipboard-tests
./build/clipboard-tests
