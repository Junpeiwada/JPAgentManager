#!/bin/bash
# ProcScan をビルドする
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p build
swiftc -O -target arm64-apple-macos26.0 main.swift -o build/ProcScan
echo "OK: $(pwd)/build/ProcScan"
