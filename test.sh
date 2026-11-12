#!/bin/zsh
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p build
swiftc -swift-version 6 Sources/Model.swift Tests/main.swift -o build/tests
./build/tests
swiftc -swift-version 6 Sources/UsageTransport.swift Tests/Transport/main.swift -o build/transport-tests
./build/transport-tests
/bin/zsh Tests/installer.sh
