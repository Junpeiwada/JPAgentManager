#!/bin/bash
# MenuBarSpike を swiftc でビルドする。出力: Spike/MenuBarSpike/build/MenuBarSpike
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p build
swiftc -swift-version 5 -target arm64-apple-macos26.0 -O \
    -o build/MenuBarSpike main.swift
echo "ビルド完了: $(pwd)/build/MenuBarSpike"
