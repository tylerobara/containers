#!/bin/sh
# Smoke test for the local-path-provisioner image.
# Usage: IMAGE=<ref> VERSION=<provisioner ver, e.g. 0.0.37> ./test.sh
set -eu
: "${IMAGE:?set IMAGE}" "${VERSION:?set VERSION}"

fail() { echo "FAIL: $1"; exit 1; }

docker run --rm --entrypoint /bin/sh "$IMAGE" -c 'command -v apk >/dev/null && exit 1; exit 0' \
  || fail "apk-tools present in prod image"

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
