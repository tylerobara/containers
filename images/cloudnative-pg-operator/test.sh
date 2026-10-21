#!/bin/sh
# Smoke test for the CloudNativePG operator image.
# Usage: IMAGE=ghcr.io/.../cloudnative-pg:1.30.1 VERSION=1.30.1 ./test.sh
set -eu
: "${IMAGE:?set IMAGE}" "${VERSION:?set VERSION (operator version, no v)}"

fail() { echo "FAIL: $1"; exit 1; }

echo "Testing operator entrypoint reports v$VERSION..."
docker run --rm --entrypoint /manager "$IMAGE" version 2>&1 \
  | grep -q "$VERSION" || fail "manager version does not report $VERSION"

echo "Testing default entrypoint is /manager..."
ep=$(docker inspect --format '{{.Config.Entrypoint}}' "$IMAGE")
[ "$ep" = "[/manager]" ] || fail "entrypoint is '$ep', expected '[/manager]'"

echo "Testing nonroot uid 65532 (upstream parity)..."
uid=$(docker inspect --format '{{.Config.User}}' "$IMAGE")
[ "$uid" = "65532" ] || fail "run-as is '$uid', expected '65532'"

echo "Testing prod restraint: busybox shell only, no bash/apk-tools..."
docker run --rm --entrypoint /bin/sh "$IMAGE" -c '
  command -v bash >/dev/null 2>&1 && exit 1
  command -v apk  >/dev/null 2>&1 && exit 1
  exit 0' || fail "bash or apk-tools present in prod image"

echo "All cloudnative-pg-operator tests passed!"
