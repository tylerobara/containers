#!/bin/sh
# Smoke test for the local-path-provisioner image.
# Usage: IMAGE=<ref> VERSION=<provisioner ver, e.g. 0.0.37> ./test.sh
set -eu
: "${IMAGE:?set IMAGE}" "${VERSION:?set VERSION}"

fail() { echo "FAIL: $1"; exit 1; }

# No debug shell (static Go, glibc-free): direct-exec must fail.
for p in /bin/sh /bin/bash /usr/bin/apk; do
  docker run --rm --entrypoint "$p" "$IMAGE" true >/dev/null 2>&1 \
    && fail "$p present in prod image" || true
done

echo "Testing --version reports v$VERSION..."
# Upstream has no startup banner and no `version` subcommand (that panics);
# the urfave/cli --version flag is the only version surface. An unstamped
# build would print "0.0.1" here, so this also proves the ldflag stamp.
out=$(docker run --rm --entrypoint /usr/bin/local-path-provisioner "$IMAGE" --version 2>&1 || true)
echo "$out" | grep -q "local-path-provisioner version v$VERSION" \
  || fail "--version does not report v$VERSION"

echo "Testing start reaches its API-server step (dies on missing in-cluster config)..."
out=$(docker run --rm --entrypoint /usr/bin/local-path-provisioner "$IMAGE" start 2>&1 || true)
echo "$out" | grep -q "unable to get client config" \
  || fail "start does not reach its API-server step"

echo "Testing entrypoint..."
ep=$(docker inspect --format '{{.Config.Entrypoint}}' "$IMAGE")
[ "$ep" = "[/usr/bin/local-path-provisioner]" ] \
  || fail "entrypoint is '$ep', expected '[/usr/bin/local-path-provisioner]'"

echo "All local-path-provisioner tests passed!"
