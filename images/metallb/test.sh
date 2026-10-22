#!/bin/sh
# Smoke test for the metallb family.
# Usage:
#   IMAGE=<controller ref> VERSION=<metallb ver> ./test.sh controller
#   IMAGE=<speaker ref>    VERSION=<metallb ver> ./test.sh speaker
#   IMAGE=<frr-k8s ref>    VERSION=<frr-k8s ver> ./test.sh frr-k8s
set -eu
: "${IMAGE:?set IMAGE}" "${VERSION:?set VERSION}"
TARGET="${1:?usage: test.sh controller|speaker|frr-k8s}"

fail() { echo "FAIL: $1"; exit 1; }

docker run --rm --entrypoint /bin/sh "$IMAGE" -c 'command -v apk >/dev/null && exit 1; exit 0' \
  || fail "apk-tools present in prod image"

case "$TARGET" in
controller)
  echo "Testing MetalLB controller banner reports $VERSION..."
  # No --version flag upstream; the JSON banner prints before the bare run
  # dies on the missing in-cluster config.
  docker run --rm --entrypoint /controller "$IMAGE" 2>&1 \
    | grep -q "MetalLB controller starting version $VERSION" \
    || fail "controller banner does not report $VERSION"

  echo "Testing entrypoint..."
  ep=$(docker inspect --format '{{.Config.Entrypoint}}' "$IMAGE")
  [ "$ep" = "[/controller]" ] || fail "entrypoint is '$ep', expected '[/controller]'"
  ;;

speaker)
  echo "Testing MetalLB speaker banner reports $VERSION..."
  docker run --rm --entrypoint /speaker "$IMAGE" 2>&1 \
    | grep -q "MetalLB speaker starting version $VERSION" \
    || fail "speaker banner does not report $VERSION"

  echo "Testing chart-required frr-tools payloads (speaker init containers)..."
  docker run --rm --entrypoint /bin/sh "$IMAGE" -ec '
    test -x /cp-tool; test -x /frr-metrics; test -x /frr-reloader.sh
    sh -n /frr-reloader.sh
    /cp-tool /frr-metrics /tmp/frr-metrics && test -x /tmp/frr-metrics' \
    || fail "chart paths /cp-tool /frr-metrics /frr-reloader.sh incomplete"

  echo "Testing entrypoint..."
  ep=$(docker inspect --format '{{.Config.Entrypoint}}' "$IMAGE")
  [ "$ep" = "[/speaker]" ] || fail "entrypoint is '$ep', expected '[/speaker]'"
  ;;

frr-k8s)
  echo "Testing the frr-k8s daemon starts (dies on missing in-cluster config)..."
  docker run --rm --entrypoint /frr-k8s "$IMAGE" 2>&1 \
    | grep -qi "in-cluster" || fail "/frr-k8s does not reach its API-server step"

  echo "Testing the toolbox payloads + init-container copy flow..."
  # Mirrors the chart's cp-reloader/cp-metrics/cp-frr-status init containers.
  docker run --rm --entrypoint /bin/sh "$IMAGE" -ec '
    test -x /frr-k8s; test -x /statuscleaner; test -x /frr-metrics
    test -x /frr-status; test -x /frr-reloader.sh
    sh -n /frr-reloader.sh
    cp -f /frr-reloader.sh /tmp/frr-reloader.sh
    cp -f /frr-metrics /tmp/frr-metrics
    cp -f /frr-status /tmp/frr-status
    test -x /tmp/frr-reloader.sh; test -x /tmp/frr-metrics; test -x /tmp/frr-status' \
    || fail "toolbox payloads /frr-k8s /statuscleaner /frr-metrics /frr-status /frr-reloader.sh incomplete"

  echo "Testing statuscleaner starts..."
  docker run --rm --entrypoint /statuscleaner "$IMAGE" 2>&1 \
    | grep -qi "in-cluster" || fail "/statuscleaner does not reach its API-server step"

  echo "Testing image has no entrypoint (upstream parity; commands are explicit)..."
  ep=$(docker inspect --format '{{.Config.Entrypoint}}' "$IMAGE")
  [ "$ep" = "[]" ] || fail "entrypoint is '$ep', expected '[]'"
  ;;

*) fail "unknown target '$TARGET'" ;;
esac

echo "All metallb/$TARGET tests passed!"
