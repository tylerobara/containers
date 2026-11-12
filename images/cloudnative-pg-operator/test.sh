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
# No shell in the image: extract the binaries and check ELF magic host-side.
tmp=$(mktemp -d)
cid=$(docker create "$IMAGE")
docker export "$cid" | tar -xf - -C "$tmp" operator/manager_amd64 operator/manager_arm64 2>/dev/null || true
docker rm "$cid" >/dev/null
[ "$(od -An -j 18 -N 1 -tu1 "$tmp/operator/manager_amd64" 2>/dev/null | tr -d ' ')" = 62 ] \
  || { rm -rf "$tmp"; fail "operator/manager_amd64 missing or wrong ELF arch"; }
[ "$(od -An -j 18 -N 1 -tu1 "$tmp/operator/manager_arm64" 2>/dev/null | tr -d ' ')" = 183 ] \
  || { rm -rf "$tmp"; fail "operator/manager_arm64 missing or wrong ELF arch"; }
rm -rf "$tmp"

echo "Testing nonroot uid 65532 (upstream parity)..."
uid=$(docker inspect --format '{{.Config.User}}' "$IMAGE")
[ "$uid" = "65532" ] || fail "run-as is '$uid', expected '65532'"

echo "Testing distroless posture: no shell at all..."
for p in /bin/sh /bin/bash /usr/bin/apk; do
  docker run --rm --entrypoint "$p" "$IMAGE" true >/dev/null 2>&1 \
    && fail "$p present in prod image" || true
done

echo "All cloudnative-pg-operator tests passed!"
