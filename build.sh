#!/bin/bash
# Build the claudepad daemon.
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p bin
swiftc -O -o bin/claudepad src/main.swift
echo "built bin/claudepad"
