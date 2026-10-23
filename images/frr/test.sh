#!/bin/sh
# Smoke test for the FRR image.
# Usage: IMAGE=ghcr.io/.../frr:10.4.3 VERSION=10.4.3 ./test.sh
set -eu
: "${IMAGE:?set IMAGE}" "${VERSION:?set VERSION (frr version, no v)}"

fail() { echo "FAIL: $1"; exit 1; }

echo "Testing daemons report v$VERSION..."
for d in zebra bgpd; do
  docker run --rm --entrypoint "/usr/lib/frr/$d" "$IMAGE" --version 2>&1 \
    | grep -q "$VERSION" || fail "$d --version does not report $VERSION"
done
# vtysh is a client CLI: no --version; its liveness is proven below via
# `vtysh -c "show version"`, here just assert the binary ships.
docker run --rm --entrypoint /bin/sh "$IMAGE" \
  -c 'test -x /usr/bin/vtysh' || fail "/usr/bin/vtysh missing"

echo "Testing default entrypoint is 'tini -- docker-start' (upstream contract)..."
ep=$(docker inspect --format '{{.Config.Entrypoint}}' "$IMAGE")
[ "$ep" = "[/sbin/tini]" ] || fail "entrypoint is '$ep', expected '[/sbin/tini]'"
cmd=$(docker inspect --format '{{.Config.Cmd}}' "$IMAGE")
[ "$cmd" = "[-- /usr/lib/frr/docker-start]" ] \
  || fail "default args are '$cmd', expected '[-- /usr/lib/frr/docker-start]'"

echo "Testing frr(92)/frrvty(85) accounts + root default user..."
user=$(docker inspect --format '{{.Config.User}}' "$IMAGE")
[ -z "$user" ] || [ "$user" = "0" ] || fail "run-as is '$user', expected root"
docker run --rm --entrypoint /bin/sh "$IMAGE" -ec '
  grep -q "^frr:[^:]*:92:92:" /etc/passwd || exit 1
  grep -q "^frrvty:[^:]*:85:" /etc/group || exit 2' \
  || fail "frr (uid 92) / frrvty (gid 85) accounts missing"

echo "Testing startup contract + sane default daemons config..."
docker run --rm --entrypoint /bin/sh "$IMAGE" -ec '
  test -x /usr/lib/frr/docker-start || exit 1
  test -x /usr/lib/frr/watchfrr || exit 2
  test -x /usr/lib/frr/frrcommon.sh || exit 3
  bash -n /usr/lib/frr/docker-start || exit 4
  grep -q 'FRR_USER=.frr.' /usr/lib/frr/frrcommon.sh || exit 5
  test -r /etc/frr/daemons || exit 6
  grep -q "^bgpd=yes" /etc/frr/daemons || exit 7
  grep -q "zebra_options" /etc/frr/daemons || exit 8' \
  || fail "startup contract broken (docker-start/watchfrr/frrcommon/daemons)"

echo "Testing the daemons come up under the default entrypoint..."
# zebra/mgmtd/bgpd cap_set_proc CAP_SYS_ADMIN in privs_init, so the bounding
# set must carry it — matches the privileged frr speakers Cilium/MetalLB run.
cid=$(docker run -d --rm --cap-add=NET_ADMIN --cap-add=NET_RAW \
  --cap-add=SYS_ADMIN "$IMAGE")
# shellcheck disable=SC2064
trap "docker stop $cid >/dev/null 2>&1 || true" EXIT
i=0
# Honest liveness contract (validated against quay.io/frrouting/frr:10.4.3,
# whose `show version` is likewise vtysh-local only): pid files, every
# daemon connected per `show daemons`, the version banner, and a real
# daemon-side answer from zebra via the vtysh->vty path.
until chk=$(docker exec -e VERSION="$VERSION" "$cid" /bin/sh -ec '
  test -s /var/run/frr/zebra.pid || { echo "no zebra.pid"; exit 1; }
  test -s /var/run/frr/bgpd.pid || { echo "no bgpd.pid"; exit 1; }
  d=$(/usr/bin/vtysh -c "show daemons" 2>/dev/null)
  for x in zebra bgpd staticd mgmtd watchfrr; do
    echo "$d" | grep -qw "$x" || { echo "show daemons=[$d] missing $x"; exit 2; }
  done
  v=$(/usr/bin/vtysh -c "show version" 2>/dev/null)
  echo "$v" | grep -q "FRRouting $VERSION" || { echo "banner=[$v]"; exit 3; }
  /usr/bin/vtysh -c "show interface lo" 2>/dev/null \
    | grep -q "Interface lo is up" || { echo "zebra vty not answering"; exit 4; }' 2>&1); do
  i=$((i + 1))
  if [ "$i" -gt 60 ]; then
    docker logs "$cid" || true
    echo "last check: $chk"
    fail "daemons never became fully operational"
  fi
  sleep 1
done
docker stop "$cid" >/dev/null
trap - EXIT

echo "All frr tests passed!"
