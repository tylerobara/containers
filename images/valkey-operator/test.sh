#!/bin/sh
# Smoke test for the Valkey operator image.
# Usage: IMAGE=ghcr.io/.../valkey-operator:0.8.0 VERSION=0.8.0 ./test.sh
set -eu
: "${IMAGE:?set IMAGE}" "${VERSION:?set VERSION (operator version, no v)}"

fail() { echo "FAIL: $1"; exit 1; }

echo "Testing the manager exposes this repo's flag surface..."
docker run --rm --entrypoint /manager "$IMAGE" --help 2>&1 \
  | grep -q "health-probe-bind-address" \
  || fail "/manager does not expose the expected flags"

echo "Testing the manager starts and reaches its API-server step..."
# No --version flag upstream; the bare run dies on the missing in-cluster
# config right after flag parsing + logger setup, which is how far a manager
# with nothing to talk to gets.
# --default-valkey-image is required since 0.9.0 (validated pre-GetConfigOrDie).
docker run --rm --entrypoint /manager "$IMAGE" --metrics-bind-address=0 \
  --default-valkey-image=ghcr.io/valkey-io/valkey:8 2>&1 \
  | grep -qiE "in-cluster|no configuration has been provided|unable to start manager" \
  || fail "/manager never reached its API-server step"

echo "Testing entrypoint + nonroot uid (upstream distroless parity)..."
ep=$(docker inspect --format '{{.Config.Entrypoint}}' "$IMAGE")
[ "$ep" = "[/manager]" ] || fail "entrypoint is '$ep', expected '[/manager]'"
uid=$(docker inspect --format '{{.Config.User}}' "$IMAGE")
[ "$uid" = "65532" ] || fail "run-as is '$uid', expected '65532'"

echo "Testing distroless posture: no shell at all..."
for p in /bin/sh /bin/bash /usr/bin/apk; do
  docker run --rm --entrypoint "$p" "$IMAGE" true >/dev/null 2>&1 \
    && fail "$p present in prod image" || true
done

echo "All valkey-operator tests passed!"
