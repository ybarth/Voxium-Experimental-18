#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

xcodebuild -scheme OpenWhisper -configuration Debug -derivedDataPath .build build \
  CODE_SIGN_IDENTITY="-" CODE_SIGN_STYLE=Manual
