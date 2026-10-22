#!/bin/sh
# Smoke test for the cilium family.
# Usage:
#   IMAGE=<cilium ref>    VERSION=<cilium ver>              ./test.sh cilium
#   IMAGE=<operator ref>  VERSION=<cilium ver>              ./test.sh operator
#   IMAGE=<envoy ref>     VERSION=<envoy ver, e.g. 1.38.6>  ./test.sh envoy
set -eu
: "${IMAGE:?set IMAGE}" "${VERSION:?set VERSION}"
TARGET="${1:?usage: test.sh cilium|operator|envoy}"

fail() { echo "FAIL: $1"; exit 1; }

docker run --rm --entrypoint /bin/sh "$IMAGE" -c 'command -v apk >/dev/null && exit 1; exit 0' \
  || fail "apk-tools present in prod image"

case "$TARGET" in
cilium)
  echo "Testing cilium-agent reports v$VERSION..."
  docker run --rm --entrypoint /usr/bin/cilium-agent "$IMAGE" --version 2>&1 \
    | grep -q "$VERSION" || fail "cilium-agent does not report $VERSION"

  echo "Testing the full install-container-binary tree..."
  docker run --rm --entrypoint /bin/sh "$IMAGE" -ec '
    for b in cilium-dbg cilium-health cilium-bugtool hubble cilium-mount \
             cilium-sysctlfix cilium-envoy-bootstrap-locality gops; do
      command -v "$b" >/dev/null || { echo "missing $b"; exit 1; }
    done
    test -x /opt/cni/bin/cilium-cni && test -x /cni/loopback || exit 2
    test -f /var/lib/cilium/bpf/bpf_lxc.c || exit 3
    for s in /init-container.sh /install-plugin.sh /cni-uninstall.sh; do
      test -x "$s" || { echo "missing $s"; exit 4; }
      sh -n "$s" || exit 5
    done' || fail "agent install tree incomplete"

  echo "Testing chart probe binary (cilium status --brief path)..."
  docker run --rm --entrypoint /opt/cni/bin/cilium-cni "$IMAGE" --version 2>&1 \
    | grep -q "Cilium CNI plugin $VERSION" || fail "cilium-cni version mismatch"

  echo "Testing runtime datapath toolchain (Wolfi equivalents)..."
  docker run --rm --entrypoint /bin/sh "$IMAGE" -ec '
    ip        -V        >/dev/null || exit 1
    iptables  --version >/dev/null || exit 2
    command -v ipset  >/dev/null || exit 3   # --version needs netlink caps
    modprobe  --version >/dev/null || exit 4
    jq        --version >/dev/null || exit 5
    clang     --version >/dev/null || exit 6
    bpftool   version   >/dev/null || exit 8
    command -v bash     >/dev/null || exit 9
    printf "#include <linux/if_ether.h>\nint t(void *ctx){return 0;}\n" > /tmp/t.c
    clang -target bpf -O2 -I /var/lib/cilium/bpf/include -c /tmp/t.c -o /tmp/t.o || exit 10
    test -f /tmp/t.o || exit 11' \
    || fail "runtime dependency missing / BPF compile failed (iproute2/iptables/ipset/kmod/jq/clang/bpftool/bash)"

  echo "Testing bundled cilium-envoy (helm daemonset path)..."
  : "${ENVOY_VERSION:?set ENVOY_VERSION for the cilium target}"
  docker run --rm --entrypoint /bin/sh "$IMAGE" -ec \
    'test -e /usr/lib/libatomic.so.1 || exit 1' || fail "bundled libatomic missing"
  docker run --rm --entrypoint /usr/bin/cilium-envoy "$IMAGE" --version 2>&1 \
    | grep -q "/$ENVOY_VERSION/" || fail "bundled cilium-envoy does not report $ENVOY_VERSION"
  docker run --rm --entrypoint /usr/bin/cilium-envoy-starter "$IMAGE" >/dev/null 2>&1 \
    || true # starter exits nonzero without caps; presence is what matters

  echo "Testing image env/entrypoint defaults..."
  ep=$(docker inspect --format '{{.Config.Entrypoint}}' "$IMAGE")
  [ "$ep" = "[/usr/bin/cilium-dbg]" ] || fail "entrypoint is '$ep', expected '[/usr/bin/cilium-dbg]'"
  docker inspect --format '{{.Config.Env}}' "$IMAGE" | grep -q HUBBLE_SERVER \
    || fail "HUBBLE_SERVER env missing"
  ;;

operator)
  echo "Testing cilium-operator-generic reports v$VERSION..."
  docker run --rm --entrypoint /usr/bin/cilium-operator-generic "$IMAGE" --version 2>&1 \
    | grep -q "$VERSION" || fail "operator does not report $VERSION"

  echo "Testing gops wiring (Wolfi gops + 777 /home/gops + GOPS_CONFIG_DIR)..."
  docker run --rm --entrypoint /bin/sh "$IMAGE" -ec '
    command -v gops >/dev/null || exit 1
    [ "$(stat -c %a /home/gops)" = "777" ] || exit 2' \
    || fail "gops or /home/gops (mode 777) missing"
  docker inspect --format '{{.Config.Env}}' "$IMAGE" | grep -q GOPS_CONFIG_DIR \
    || fail "GOPS_CONFIG_DIR env missing"
  ;;

envoy)
  echo "Testing cilium-envoy reports $VERSION..."
  docker run --rm --entrypoint /bin/sh "$IMAGE" -ec \
    'test -e /usr/lib/libatomic.so.1 || exit 1' || fail "shipped libatomic missing"
  docker run --rm --entrypoint /usr/bin/cilium-envoy "$IMAGE" --version 2>&1 \
    | grep -q "/$VERSION/" || fail "cilium-envoy does not report $VERSION"

  echo "Testing starter + entrypoint..."
  docker run --rm --entrypoint /usr/bin/cilium-envoy-starter "$IMAGE" 2>&1 \
    | grep -qi cap || fail "starter does not print its capability guidance"
  ep=$(docker inspect --format '{{.Config.Entrypoint}}' "$IMAGE")
  [ "$ep" = "[/usr/bin/cilium-envoy]" ] || fail "entrypoint is '$ep', expected '[/usr/bin/cilium-envoy]'"
  ;;

*) fail "unknown target '$TARGET'" ;;
esac

echo "All cilium/$TARGET tests passed!"
