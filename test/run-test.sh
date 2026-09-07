#!/usr/bin/env bash
# Build and run the clean-room install test.
#
#   ./test/run-test.sh            # build + run
#   ./test/run-test.sh --shell    # drop into the container instead
#
# Validates the INSTALL path only — no GPU, no display, so it cannot check
# rendering, sensors, or the game itself. What it does check is the failure that
# is genuinely hard to diagnose: wine-mono instead of real .NET 4.8, which makes
# ZwiftLauncher.exe exit 200 with no other symptom.
set -euo pipefail

cd "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IMAGE=zwift-on-linux-test

echo "==> building $IMAGE"
docker build -f test/Dockerfile -t "$IMAGE" .

if [ "${1:-}" = "--shell" ]; then
  exec docker run --rm -it --entrypoint /bin/bash "$IMAGE"
fi

echo "==> running test (this takes ~10-15 min; dotnet48 is slow)"
docker run --rm "$IMAGE"
