#!/usr/bin/env bash
# Shell entry point for the shared module validator and packager.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BINARY_ARM64="${1:-target/aarch64-linux-android/release/duckd}"
BINARY_X86_64="${2:-target/x86_64-linux-android/release/duckd}"
DIST_DIR="${3:-dist}"

VERSION="$(python3 -c 'import pathlib, sys; print(next(line.split("=", 1)[1].strip() for line in pathlib.Path(sys.argv[1]).read_text().splitlines() if line.startswith("version=")))' "${REPO_ROOT}/module/module.prop")"
exec python3 "${REPO_ROOT}/scripts/package-module.py" \
    --binary-arm64 "${BINARY_ARM64}" --binary-x86_64 "${BINARY_X86_64}" \
    --output "${DIST_DIR}/duck-toolbox-${VERSION}.zip"
