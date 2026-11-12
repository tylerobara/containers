#!/bin/sh
# Smoke + FIPS test for the Traefik FIPS image (traefik:<ver>-fips tags).
# Usage: IMAGE=ghcr.io/.../traefik:3.7.17-fips VERSION=3.7.17 ./test.sh
# Needs on the host: docker, go (for `go version -m` build-info assertions).
set -eu
: "${IMAGE:?set IMAGE}" "${VERSION:?set VERSION (traefik version, no v)}"

fail() { echo "FAIL: $1"; exit 1; }
command -v go >/dev/null 2>&1 || fail "go toolchain required on the test host (build-info assertions)"

dyn=$(mktemp -d); chmod 755 "$dyn"
# shellcheck disable=SC2064
trap "rm -rf '$dyn' || true" EXIT

echo "Testing traefik reports v$VERSION..."
docker run --rm --entrypoint /usr/bin/traefik "$IMAGE" version 2>&1 \
  | grep -q "v$VERSION" || fail "traefik version does not report v$VERSION"

echo "Testing drop-in entrypoint is /usr/bin/traefik (same as the plain tags)..."
ep=$(docker inspect --format '{{.Config.Entrypoint}}' "$IMAGE")
[ "$ep" = "[/usr/bin/traefik]" ] || fail "entrypoint is '$ep', expected '[/usr/bin/traefik]'"

echo "Testing nonroot uid 65532..."
uid=$(docker inspect --format '{{.Config.User}}' "$IMAGE")
[ "$uid" = "65532" ] || fail "run-as is '$uid', expected '65532'"

echo "Testing distroless posture: no shell at all..."
for p in /bin/sh /bin/bash /usr/bin/apk; do
  docker run --rm --entrypoint "$p" "$IMAGE" true >/dev/null 2>&1 \
    && fail "$p present in prod image" || true
done

echo "Testing FIPS build info (GOFIPS140=v1.0.0 + fips140=on baked in)..."
cid=$(docker create "$IMAGE")
bin="$PWD/.traefik-fips.$$.bin"
docker cp "$cid:/usr/bin/traefik" "$bin" >/dev/null
docker rm "$cid" >/dev/null
go version -m "$bin" >"$bin.info"
grep -q 'GOFIPS140=v1.0.0'               "$bin.info" || fail "binary not built against the CMVP #5247 module snapshot"
grep -q 'DefaultGODEBUG=fips140=on'      "$bin.info" || fail "binary does not default to FIPS 140-3 mode"
rm -f "$bin" "$bin.info"

echo "Testing provider-less boot with --ping (/ping on :8080)..."
# Same as the non-FIPS image's posture: the internal provider alone starts.
cid=$(docker run -d --rm -p 127.0.0.1::8080 "$IMAGE" \
  --entrypoints.web.address=:80 --ping --api.dashboard=false)
# shellcheck disable=SC2064
trap "docker stop $cid >/dev/null 2>&1 || true; rm -rf '$dyn' || true" EXIT
port=$(docker port "$cid" 8080/tcp | head -1 | sed 's/.*://')
i=0
until curl -fsS --max-time 5 "http://127.0.0.1:${port}/ping" 2>/dev/null | grep -q OK; do
  i=$((i + 1))
  [ "$i" -gt 30 ] && { docker logs "$cid" 2>&1 || true; fail "ping endpoint never came up"; }
  sleep 1
done
docker stop "$cid" >/dev/null

echo "Testing FIPS TLS boundary on websecure (approved suites accepted, non-approved refused)..."
# TLS terminates in the compiled-in Go module's FIPS mode: crypto/tls only
# negotiates FIPS-approved versions/ciphersuites (equivalent of fipsonly).
# Client is OpenSSL from a wolfi container sharing traefik's netns (the prod
# image is deliberately static and shell-less).
cat >"$dyn/tls.yml" <<'EOF'
http:
  routers:
    tlstest:
      rule: "PathPrefix(`/`)"
      entryPoints:
        - websecure
      service: blackhole
      tls: {}
  services:
    blackhole:
      loadBalancer:
        servers:
          - url: "http://127.0.0.1:9"
EOF
# Router with tls:{} and no certFile → traefik serves its auto-generated
# default certificate (RSA self-signed), which also exercises the module's
# key-generation pairwise self-test under FIPS mode.
cid=$(docker run -d --rm -v "$dyn:/etc/traefik-dyn:ro" "$IMAGE" \
  --entrypoints.web.address=:80 --entrypoints.websecure.address=:443 \
  --providers.file.directory=/etc/traefik-dyn --api.dashboard=false)
# shellcheck disable=SC2064
trap "docker stop $cid >/dev/null 2>&1 || true; rm -rf '$dyn' || true" EXIT
sleep 3   # entrypoint/router settle; handshake assertions have their own retries

docker run --rm --network "container:$cid" --entrypoint /bin/sh \
  cgr.dev/chainguard/wolfi-base:latest -c '
    apk update >/dev/null 2>&1 && apk add --no-cache openssl >/dev/null 2>&1 \
      || { echo "could not install openssl in test client container"; exit 90; }
    o() { openssl s_client -connect 127.0.0.1:443 -servername fips.test "$@" </dev/null 2>&1 || true; }
    # Wait for the websecure entrypoint to come up (retry only the positive
    # probe — negative probes are EXPECTED to fail, no retrying those).
    i=0
    until o -tls1_3 | grep -qE "Cipher is TLS_AES_(128|256)_GCM"; do
      i=$((i + 1)); [ "$i" -gt 20 ] && { echo "FAIL: approved TLS1.3 suite never negotiated"; exit 1; }
      sleep 1
    done
    # Positive: TLS 1.2 ECDHE-RSA-AES-GCM (FIPS-approved) must negotiate.
    o -tls1_2 -cipher ECDHE-RSA-AES256-GCM-SHA384 \
      | grep -q "Cipher is ECDHE-RSA-AES256-GCM-SHA384" \
      || { echo "FAIL: approved TLS1.2 ECDHE-RSA-AES256-GCM-SHA384 did not negotiate"; exit 2; }
    # Negative - the FIPS discriminators: ChaCha20-Poly1305 IS in the Traefik
    # default cipher policy and IS supported by stock Go crypto/tls, but is
    # outside the FIPS-approved set. Control-tested 2026-11-02 against the
    # published non-FIPS image (ghcr.io/tylerobara/containers/traefik:3.7.17):
    # both CHACHA20 handshakes ACCEPT there, both REFUSE here. (AES128-SHA is
    # refused by BOTH images - the Traefik default TLS policy excludes
    # static-RSA suites - so it proves nothing about FIPS and is deliberately
    # not tested.)
    o -tls1_2 -cipher ECDHE-RSA-CHACHA20-POLY1305 \
      | grep -q "Cipher is ECDHE-RSA-CHACHA20-POLY1305" \
      && { echo "FAIL: non-approved TLS1.2 CHACHA20-POLY1305 negotiated — FIPS mode is OFF"; exit 3; }
    o -tls1_3 -ciphersuites TLS_CHACHA20_POLY1305_SHA256 \
      | grep -q "Cipher is TLS_CHACHA20_POLY1305_SHA256" \
      && { echo "FAIL: non-approved TLS1.3 CHACHA20-POLY1305 negotiated — FIPS mode is OFF"; exit 4; }
    echo "tls battery ok"' || fail "FIPS TLS boundary test failed"

docker stop "$cid" >/dev/null
trap - EXIT

echo "All traefik-fips tests passed!"
