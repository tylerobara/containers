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

echo "Testing multi-arch manager binaries under /operator/ ..."
# The reconciler refuses to write Cluster status unless operator/manager_<goarch>
# exists ("cannot update the resource status: invalid architecture: arm64"), and
# it cross-populates every arch it bundles. Each CI leg builds natively, so only
# an in-image ELF-magic check catches a missing/cross-contaminated leg.
# e_machine byte: 62 = x86_64, 183 = aarch64.
docker run --rm --entrypoint /bin/sh "$IMAGE" -c '
  [ -x /operator/manager_amd64 ] || exit 1
  [ -x /operator/manager_arm64 ] || exit 1
  [ "$(od -An -j 18 -N 1 -tu1 /operator/manager_amd64 | tr -d " ")" = 62 ] || exit 1
  [ "$(od -An -j 18 -N 1 -tu1 /operator/manager_arm64 | tr -d " ")" = 183 ] || exit 1
  exit 0' || fail "operator/manager_{amd64,arm64} missing or wrong ELF arch"

echo "Testing nonroot uid 65532 (upstream parity)..."
uid=$(docker inspect --format '{{.Config.User}}' "$IMAGE")
[ "$uid" = "65532" ] || fail "run-as is '$uid', expected '65532'"

echo "Testing prod restraint: busybox shell only, no bash/apk-tools..."
docker run --rm --entrypoint /bin/sh "$IMAGE" -c '
  command -v bash >/dev/null 2>&1 && exit 1
  command -v apk  >/dev/null 2>&1 && exit 1
  exit 0' || fail "bash or apk-tools present in prod image"

echo "All cloudnative-pg-operator tests passed!"
