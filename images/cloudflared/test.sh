#!/bin/sh
# Smoke test for the cloudflared image (Cloudflare Tunnel agent: one static Go
# binary, a pure outbound-connect tool — no ports, nothing to wait for).
# Usage: IMAGE=<ref> VERSION=<cloudflared ver, e.g. 2026.10.5> ./test.sh
set -eu
: "${IMAGE:?set IMAGE}" "${VERSION:?set VERSION (cloudflared version, e.g. 2026.10.5)}"

fail() { echo "FAIL: $1"; exit 1; }

echo "Testing entrypoint is upstream's [cloudflared --no-autoupdate]..."
ep=$(docker inspect --format '{{.Config.Entrypoint}}' "$IMAGE")
[ "$ep" = "[/usr/bin/cloudflared --no-autoupdate]" ] \
  || fail "entrypoint is '$ep', expected '[/usr/bin/cloudflared --no-autoupdate]'"

echo "Testing default cmd is upstream's [version]..."
cmd=$(docker inspect --format '{{.Config.Cmd}}' "$IMAGE")
[ "$cmd" = "[version]" ] || fail "cmd is '$cmd', expected '[version]'"

echo "Testing nonroot uid 65532 (upstream USER 65532:65532, distroless nonroot)..."
uid=$(docker inspect --format '{{.Config.User}}' "$IMAGE")
[ "$uid" = "65532" ] || fail "run-as is '$uid', expected '65532'"

echo "Testing distroless posture: no shell at all..."
for p in /bin/sh /bin/bash /usr/bin/apk; do
  docker run --rm --entrypoint "$p" "$IMAGE" true >/dev/null 2>&1 \
    && fail "$p present in prod image" || true
done

echo "Testing version anchor: installed apk is exactly ${VERSION}-r100..."
# Wolfi DOES ship a cloudflared package, so this check is load-bearing: if the
# epoch-100/provider-priority ever loses resolution, the installed pkgver reads
# as Wolfi's 2026.x.y-rN here (the workflow's lock guard asserts the same
# thing pre-publish; gatus/valkey precedent).
# No shell in the image: read the apk db from the host side.
cid=$(docker create "$IMAGE")
db=$(docker export "$cid" | tar -xO lib/apk/db/installed 2>/dev/null || true)
docker rm "$cid" >/dev/null
echo "$db" | grep -q '^P:cloudflared$' \
  || fail "cloudflared apk not installed"
[ "$(echo "$db" | grep -A1 '^P:cloudflared$' | tail -1)" = "V:${VERSION}-r100" ] \
  || fail "installed apk is not exactly cloudflared ${VERSION}-r100"

echo "Testing --version prints exactly ${VERSION} (the ldflag stamp, no DEV/unknown)..."
# Upstream stamps main.Version/main.BuildTime via ldflags; without the stamp
# the binary prints main.go's 'DEV' default or an 'unknown' build time. Assert
# the full upstream --version shape, which excludes both — and the melange
# build already pinned the BuildTime recipe (RELEASE_NOTES mtime), so only the
# version number itself may vary. Every assertion below runs --network none:
# these code paths (version/help) are handled before the app action layer, so
# no Cloudflare auth or network is needed.
out=$(docker run --rm --network none --entrypoint /usr/bin/cloudflared "$IMAGE" --version 2>&1)
echo "$out"
echo "$out" | grep -Eq "^cloudflared version ${VERSION} \(built [0-9]{4}-[0-9]{2}-[0-9]{2}-[0-9]{2}:[0-9]{2} UTC\)$" \
  || fail "--version is '$out', expected 'cloudflared version ${VERSION} (built <date> UTC)' — version stamp lost"

echo "Testing 'version --short' prints exactly ${VERSION} and bare run (upstream CMD version) exits 0..."
short=$(docker run --rm --network none --entrypoint /usr/bin/cloudflared "$IMAGE" version --short 2>&1)
[ "$short" = "$VERSION" ] || fail "'version --short' printed '$short', expected exactly '${VERSION}'"
out=$(docker run --rm --network none "$IMAGE" 2>&1)
echo "$out"
echo "$out" | grep -Eq "^cloudflared version ${VERSION} \(built" \
  || fail "bare run (entrypoint+cmd 'version') printed '$out', expected the ${VERSION} version line"

echo "Testing --help lists the tunnel command..."
docker run --rm --network none --entrypoint /usr/bin/cloudflared "$IMAGE" --help 2>&1 \
  | grep -Eq "^[[:space:]]+tunnel" || fail "--help missing tunnel command"

echo "Testing tunnel subcommand surface (create/run/list/login)..."
tunnel_help=$(docker run --rm --network none --entrypoint /usr/bin/cloudflared "$IMAGE" tunnel --help 2>&1)
for sub in create run list login; do
  echo "$tunnel_help" | grep -Eq "^[[:space:]]+${sub}\b" || fail "tunnel --help missing ${sub} subcommand"
done

echo "Testing 'tunnel login --help' surfaces exit 0 offline (no Cloudflare auth)..."
docker run --rm --network none --entrypoint /usr/bin/cloudflared "$IMAGE" \
  tunnel login --help >/dev/null 2>&1 || fail "tunnel login --help did not exit 0"

echo "All cloudflared tests passed!"
