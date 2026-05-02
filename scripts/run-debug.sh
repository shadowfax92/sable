#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_PATH="$("$ROOT/scripts/build-app.sh")"
open "$APP_PATH"
