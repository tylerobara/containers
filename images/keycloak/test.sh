#!/bin/sh
# Smoke test for the keycloak image (Keycloak IAM/SSO: the melange-built dist
# from the upstream release tarball, kc.sh build baked, Wolfi JRE runtime).
# Usage: IMAGE=<ref> VERSION=<keycloak ver, e.g. 26.8.1> ./test.sh
set -eu
: "${IMAGE:?set IMAGE}" "${VERSION:?set VERSION (keycloak version, e.g. 26.8.1)}"

fail() { echo "FAIL: $1"; exit 1; }

echo "Testing entrypoint is upstream's [kc.sh] with cmd [start]..."
ep=$(docker inspect --format '{{.Config.Entrypoint}}' "$IMAGE")
[ "$ep" = "[/opt/keycloak/bin/kc.sh]" ] \
  || fail "entrypoint is '$ep', expected '[/opt/keycloak/bin/kc.sh]'"
cmd=$(docker inspect --format '{{.Config.Cmd}}' "$IMAGE")
[ "$cmd" = "[start]" ] || fail "cmd is '$cmd', expected '[start]'"

echo "Testing nonroot uid 65532 (repo-wide numeric nonroot)..."
uid=$(docker inspect --format '{{.Config.User}}' "$IMAGE")
[ "$uid" = "65532" ] || fail "run-as is '$uid', expected '65532'"

echo "Testing prod restraint: busybox shell only, no bash/apk-tools..."
docker run --rm --entrypoint /bin/sh "$IMAGE" -c '
  command -v bash >/dev/null 2>&1 && exit 1
  command -v apk  >/dev/null 2>&1 && exit 1
  exit 0' || fail "bash or apk-tools present in prod image"

echo "Testing version anchor: installed apk is exactly ${VERSION}-r100..."
# Wolfi ships only stream-named keycloak-26.5/26.6 packages today, so the
# bare name resolving to ours is the expectation — but this check is the
# load-bearing guard (workflow lock guard + cloudflared/valkey precedent) if
# a bare keycloak package ever appears upstream.
docker run --rm --network none --entrypoint /bin/sh "$IMAGE" -ec "
  grep -q '^P:keycloak\$' /lib/apk/db/installed \
    || { echo 'keycloak apk not installed'; exit 1; }
  awk '/^P:keycloak\$/{getline; ok=(\$0==\"V:${VERSION}-r100\"); print \$0; exit !ok}' /lib/apk/db/installed" \
  || fail "installed apk is not exactly keycloak ${VERSION}-r100"

echo "Testing JAVA_HOME (Wolfi JRE puts no java on PATH; kc.sh needs it)..."
docker run --rm --network none --entrypoint /bin/sh "$IMAGE" -ec '
  [ -n "${JAVA_HOME:-}" ] && [ -x "$JAVA_HOME/bin/java" ]' \
  || fail "JAVA_HOME missing or has no bin/java in the image"

echo "Testing kc.sh --version prints exactly ${VERSION}..."
# Upstream --version first line is `Keycloak <ver>` (then JVM/OS lines);
# assert the pinned version exactly, no network needed.
out=$(docker run --rm --network none --entrypoint /opt/keycloak/bin/kc.sh "$IMAGE" --version 2>&1)
echo "$out"
echo "$out" | head -1 | grep -Eq "^Keycloak ${VERSION}$" \
  || fail "--version first line is '$(echo "$out" | head -1)', want 'Keycloak ${VERSION}'"

echo "Testing boot: start-dev serves :8080, management health/ready UP on :9000..."
# The full contract — built dist boots as uid 65532 with the apk-shipped
# data/ (0777) bootstrapping the H2 db, and kc.sh re-augmenting lib/quarkus
# for the dev profile, exactly as a first `docker run` would. Host-side
# probe (traefik/openbao precedent): the image's busybox ships no wget/curl
# applet, so publish the ports on loopback and curl from the runner.
# start-dev (not production start) so plain HTTP is allowed. Health lives on
# the MANAGEMENT port 9000 (probed: KC_HEALTH_ENABLED=true binds :9000; the
# main port 404s /health even in dev mode). The endpoints are OFF by default
# even in dev mode — the image bakes KC_HEALTH_ENABLED=true (apko env) so
# this probe, like a k8s probe, hits the bare image contract with zero
# overrides; KC_HTTP_HOST=0.0.0.0 likewise comes from the image env, not
# from flags here. (Probed: dev mode PRETTY-PRINTS the health JSON —
# `"status": "UP"` with a space — hence the space-tolerant grep; DOWN would
# answer 503 and fail -f anyway.) Deployment shape (KC_DB_*, TLS certs,
# production start) is per-deployment state per upstream docs, not baked
# here.
cid=$(docker run -d --rm -p 127.0.0.1::8080 -p 127.0.0.1::9000 \
  --entrypoint /opt/keycloak/bin/kc.sh "$IMAGE" start-dev --http-port=8080)
port=$(docker port "$cid" 8080/tcp | head -1 | sed 's/.*://')
mport=$(docker port "$cid" 9000/tcp | head -1 | sed 's/.*://')
i=0
until curl -fsS --max-time 5 "http://127.0.0.1:${mport}/health/ready" 2>/dev/null \
  | grep -Eq '"status": ?"UP"'; do
  i=$((i + 1))
  [ "$i" -gt 60 ] && { docker logs "$cid" 2>&1 | tail -40; docker rm -f "$cid" >/dev/null 2>&1; fail "keycloak did not reach health/ready UP in ~180s"; }
  sleep 3
done
echo "health/ready UP after ~$((i * 3))s"

echo "Testing the root realm serves on :8080..."
# Probed against the shipped perms: / is the welcome page (200, NOT a 302 —
# there is no default-context-path redirect in KC 26) and /realms/master
# serves the master realm document.
code=$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:${port}/")
[ "$code" = "200" ] \
  || { docker logs "$cid" 2>&1 | tail -20; docker rm -f "$cid" >/dev/null 2>&1; fail "GET / returned $code, want 200 (welcome page)"; }
code=$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:${port}/realms/master")
[ "$code" = "200" ] \
  || { docker logs "$cid" 2>&1 | tail -20; docker rm -f "$cid" >/dev/null 2>&1; fail "GET /realms/master returned $code, want 200"; }
docker rm -f "$cid" > /dev/null 2>&1
echo "All keycloak tests passed!"
