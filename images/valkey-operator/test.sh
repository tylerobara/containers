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
docker run --rm --entrypoint /manager "$IMAGE" --metrics-bind-address=0 2>&1 \
  | grep -qiE "in-cluster|no configuration has been provided|unable to start manager" \
  || fail "/manager never reached its API-server step"

echo "Testing entrypoint + nonroot uid (upstream distroless parity)..."
ep=$(docker inspect --format '{{.Config.Entrypoint}}' "$IMAGE")
[ "$ep" = "[/manager]" ] || fail "entrypoint is '$ep', expected '[/manager]'"
uid=$(docker inspect --format '{{.Config.User}}' "$IMAGE")
[ "$uid" = "65532" ] || fail "run-as is '$uid', expected '65532'"

echo "Testing prod restraint: busybox shell only, no bash/apk-tools..."
docker run --rm --entrypoint /bin/sh "$IMAGE" -c '
  command -v bash >/dev/null 2>&1 && exit 1
  command -v apk  >/dev/null 2>&1 && exit 1
  exit 0' || fail "bash or apk-tools present in prod image"

echo "All valkey-operator tests passed!"
