#!/usr/bin/env bash
# Builds a debug .app bundle and launches it.
set -euo pipefail

cd "$(dirname "$0")/.."

CONFIG=debug scripts/build-app.sh
open build/AdbFiles.app
