#!/bin/sh
# Smoke test for the pocket-id family.
# Usage:
#   IMAGE=<pocket-id ref>     VERSION=<pocket-id ver, e.g. 2.18.0> ./test.sh pocket-id
#   IMAGE=<operator ref>      VERSION=<operator ver, e.g. 0.15.0>  ./test.sh pocket-id-operator
set -eu
: "${IMAGE:?set IMAGE}" "${VERSION:?set VERSION}"
TARGET="${1:?usage: test.sh pocket-id|pocket-id-operator}"

fail() { echo "FAIL: $1"; exit 1; }

docker run --rm --entrypoint /bin/sh "$IMAGE" -c 'command -v apk >/dev/null && exit 1; exit 0' \
  || fail "apk-tools present in prod image"

case "$TARGET" in
pocket-id)
  echo "Testing pocket-id reports v$VERSION..."
  # `version` is on shouldSkipEnvValidation's allow list, so it runs without
  # an ENCRYPTION_KEY/DB and proves the -X internal/common.Version stamp.
  docker run --rm --entrypoint /usr/bin/pocket-id "$IMAGE" version 2>&1 \
    | grep -qx "pocket-id $VERSION" \
    || fail "pocket-id version does not report $VERSION"

  echo "Testing entrypoint, nonroot uid + APP_ENV..."
  ep=$(docker inspect --format '{{.Config.Entrypoint}}' "$IMAGE")
  [ "$ep" = "[/usr/bin/pocket-id]" ] || fail "entrypoint is '$ep', expected '[/usr/bin/pocket-id]'"
  uid=$(docker inspect --format '{{.Config.User}}' "$IMAGE")
  [ "$uid" = "65532" ] || fail "run-as is '$uid', expected '65532'"
  docker inspect --format '{{range .Config.Env}}{{println .}}{{end}}' "$IMAGE" \
    | grep -qx 'APP_ENV=production' || fail "APP_ENV=production not set in the image"
  docker inspect --format '{{range .Config.Env}}{{println .}}{{end}}' "$IMAGE" \
    | grep -qx 'UPLOAD_PATH=/app/data/uploads' \
    || fail "UPLOAD_PATH not pinned into the /app/data volume (apko has no WORKDIR)"
  docker inspect --format '{{range .Config.Env}}{{println .}}{{end}}' "$IMAGE" \
    | grep -qx 'DB_CONNECTION_STRING=/app/data/pocket-id.db' \
    || fail "DB_CONNECTION_STRING not pinned into the /app/data volume (apko has no WORKDIR)"

  echo "Testing /app/data exists + is nonroot-writable (SQLite volume dir)..."
  docker run --rm --entrypoint /bin/sh "$IMAGE" -ec \
    'test -d /app/data && [ -w /app/data ]' \
    || fail "/app/data missing or not writable by the default user"

  echo "Testing the server boots and serves the embedded SvelteKit bundle..."
  # The image has NO HTTP client (Wolfi busybox is built without the wget
  # applet), so the page fetch runs from the host against a published port —
  # valid because the server binds 0.0.0.0:1411 — while the health probe
  # stays in-container via the upstream healthcheck subcommand below. The
  # absolute UPLOAD_PATH/DB paths come from the baked image env, exactly as
  # the chart/operator deployments get them.
  cid=$(docker run -d --rm -p 127.0.0.1::1411 \
    -e ENCRYPTION_KEY=test-encryption-key-0123456789abcdef \
    -e APP_URL=http://localhost:1411 \
    -e VERSION_CHECK_DISABLED=true \
    -e ANALYTICS_DISABLED=true \
    "$IMAGE")
  # shellcheck disable=SC2064
  trap "docker stop $cid >/dev/null 2>&1 || true" EXIT
  port=$(docker port "$cid" 1411/tcp | head -1 | awk -F: '{print $NF}')
  i=0
  until curl -sf "http://127.0.0.1:${port}/" | grep -q "_app/immutable"; do
    i=$((i + 1))
    if [ "$i" -gt 60 ]; then
      docker logs "$cid" 2>&1 | tail -30
      fail "server never served the embedded frontend"
    fi
    sleep 1
  done

  echo "Testing the upstream HEALTHCHECK command..."
  docker exec "$cid" /usr/bin/pocket-id healthcheck \
    || fail "'pocket-id healthcheck' failed against the running server"
  docker stop "$cid" >/dev/null
  trap - EXIT

  echo "All pocket-id tests passed!"
  ;;

pocket-id-operator)
  echo "Testing the manager exposes this repo's flag surface..."
  docker run --rm --entrypoint /manager "$IMAGE" --help 2>&1 \
    | grep -q "health-probe-bind-address" \
    || fail "/manager does not expose the expected flags"

  echo "Testing the manager starts and reaches its API-server step..."
  # No --version flag upstream; the bare run dies on the missing in-cluster
  # config right after flag parsing + logger setup, which is how far a manager
  # with nothing to talk to gets.
  docker run --rm --entrypoint /manager "$IMAGE" --metrics-bind-address=0 2>&1 \
    | grep -qiE "in-cluster|no configuration has been provided|unable to start manager" \
    || fail "/manager never reached its API-server step"

  echo "Testing entrypoint + nonroot uid (chart runs command: [/manager])..."
  ep=$(docker inspect --format '{{.Config.Entrypoint}}' "$IMAGE")
  [ "$ep" = "[/manager]" ] || fail "entrypoint is '$ep', expected '[/manager]'"
  uid=$(docker inspect --format '{{.Config.User}}' "$IMAGE")
  [ "$uid" = "65532" ] || fail "run-as is '$uid', expected '65532'"

  echo "All pocket-id-operator tests passed!"
  ;;

*) fail "unknown target '$TARGET'" ;;
esac
