#!/bin/sh
# Smoke test for the cert-manager family.
# Usage:
#   IMAGE=<ref> VERSION=<cert-manager ver, e.g. 1.21.2> ./test.sh controller|cainjector|webhook
set -eu
: "${IMAGE:?set IMAGE}" "${VERSION:?set VERSION}"
TARGET="${1:?usage: test.sh controller|cainjector|webhook}"

fail() { echo "FAIL: $1"; exit 1; }
case "$TARGET" in
  controller) BIN=cert-manager-controller; BANNER="starting cert-manager controller" ;;
  cainjector) BIN=cert-manager-cainjector; BANNER="starting cert-manager ca-injector" ;;
  webhook)    BIN=cert-manager-webhook;    BANNER="starting cert-manager webhook" ;;
  *) fail "unknown target '$TARGET'" ;;
esac

docker run --rm --entrypoint /bin/sh "$IMAGE" -c 'command -v apk >/dev/null && exit 1; exit 0' \
  || fail "apk-tools present in prod image"

echo "Testing $BIN startup banner reports v$VERSION..."
# No --version flag upstream; the banner prints before the binary dies on
# missing in-cluster config. --user 1001 mirrors the helm chart's
# runAsUser (the binary must be executable by the chart's uid).
out=$(docker run --rm --user 1001:1001 --entrypoint "/usr/bin/$BIN" "$IMAGE" 2>&1 || true)
echo "$out" | grep -q "$BANNER" || fail "$BIN did not log its startup banner"
echo "$out" | grep -q "version=\"v$VERSION\"" || fail "$BIN does not report v$VERSION"

echo "Testing image entrypoint default..."
ep=$(docker inspect --format '{{.Config.Entrypoint}}' "$IMAGE")
[ "$ep" = "[/usr/bin/$BIN]" ] || fail "entrypoint is '$ep', expected '[/usr/bin/$BIN]'"

echo "All cert-manager/$TARGET tests passed!"
