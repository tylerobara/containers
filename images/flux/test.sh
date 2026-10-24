#!/bin/sh
# Smoke test for the flux controller family (four separate upstream repos:
# github.com/fluxcd/<target>).
# Usage:
#   IMAGE=<ref> VERSION=<controller ver, e.g. 1.9.6> ./test.sh \
#     helm-controller|kustomize-controller|notification-controller|source-controller
set -eu
: "${IMAGE:?set IMAGE}" "${VERSION:?set VERSION}"
TARGET="${1:?usage: test.sh helm-controller|kustomize-controller|notification-controller|source-controller}"

fail() { echo "FAIL: $1"; exit 1; }

docker run --rm --entrypoint /bin/sh "$IMAGE" -c 'command -v apk >/dev/null && exit 1; exit 0' \
  || fail "apk-tools present in prod image"

case "$TARGET" in
  helm-controller)         FLAG=--oom-watch-interval ;;
  kustomize-controller)    FLAG=--concurrent-ssa ;;
  notification-controller) FLAG=--rate-limit-interval ;;
  source-controller)       FLAG=--helm-index-max-size ;;
  *) fail "unknown target '$TARGET'" ;;
esac

echo "Testing $TARGET v$VERSION reaches its in-cluster config step..."
# Upstream has no --version flag (the release binaries reject it; the version
# ships only as an OCI annotation on the image), so the bare run dying on the
# missing in-cluster config is the liveness signal. The version itself is
# sha256-pinned at the melange build, not re-derivable from the binary.
docker run --rm --entrypoint "/usr/bin/$TARGET" "$IMAGE" 2>&1 \
  | grep -q "in-cluster" || fail "$TARGET does not reach its API-server step"

echo "Testing $TARGET flag surface (correct controller binary)..."
# --version is an unknown flag upstream; pflag dumps the full flag surface on
# the way out, so the (non-zero) exit status still carries the whole dump.
docker run --rm --entrypoint "/usr/bin/$TARGET" "$IMAGE" --version 2>&1 \
  | grep -q -- "$FLAG" || fail "$TARGET flag surface lacks $FLAG"

echo "Testing entrypoint..."
ep=$(docker inspect --format '{{.Config.Entrypoint}}' "$IMAGE")
[ "$ep" = "[/usr/bin/$TARGET]" ] || fail "entrypoint is '$ep', expected '[/usr/bin/$TARGET]'"

echo "All flux/$TARGET tests passed!"
