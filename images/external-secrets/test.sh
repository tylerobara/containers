#!/bin/sh
# Smoke test for the External Secrets Operator image (one image, one binary:
# controller = root command, webhook + certcontroller = cobra subcommands).
# Usage: IMAGE=<ref> VERSION=<external-secrets ver, e.g. 2.14.0> ./test.sh
set -eu
: "${IMAGE:?set IMAGE}" "${VERSION:?set VERSION (external-secrets version, no v)}"

fail() { echo "FAIL: $1"; exit 1; }

echo "Testing entrypoint is /usr/bin/external-secrets..."
ep=$(docker inspect --format '{{.Config.Entrypoint}}' "$IMAGE")
[ "$ep" = "[/usr/bin/external-secrets]" ] || fail "entrypoint is '$ep', expected '[/usr/bin/external-secrets]'"

echo "Testing nonroot uid 65534 (upstream USER 65534)..."
uid=$(docker inspect --format '{{.Config.User}}' "$IMAGE")
[ "$uid" = "65534" ] || fail "run-as is '$uid', expected '65534'"

echo "Testing prod restraint: busybox shell only, no bash/apk-tools..."
docker run --rm --entrypoint /bin/sh "$IMAGE" -c '
  command -v bash >/dev/null 2>&1 && exit 1
  command -v apk  >/dev/null 2>&1 && exit 1
  exit 0' || fail "bash or apk-tools present in prod image"

echo "Testing version anchor: installed apk is exactly ${VERSION}-r100..."
# Upstream stamps NOTHING into the binary (the Makefile passes no ldflags, the
# cobra root sets no Version, so --version is an unknown flag — the flux
# family's documented situation). The binary's own --help/--version CANNOT
# report 2.14.0; the version anchor is the sha256-pinned tarball verified by
# the melange build, and what this image can honestly prove is that the
# installed apk is exactly our melange package at the pinned version — fail
# loudly on 'unknown' or any mismatch (a Wolfi-index external-secrets apk
# does not exist, so any other pkgver means resolution went wrong).
docker run --rm --entrypoint /bin/sh "$IMAGE" -ec "
  grep -q '^P:external-secrets\$' /lib/apk/db/installed \
    || { echo 'external-secrets apk not installed'; exit 1; }
  awk '/^P:external-secrets\$/{getline; ok=(\$0==\"V:${VERSION}-r100\"); print \$0; exit !ok}' /lib/apk/db/installed" \
  || fail "installed apk is not exactly external-secrets ${VERSION}-r100"

echo "Testing controller reaches its in-cluster config step..."
# The controller tries the kube-apiserver on plain startup and dies without
# one, so a flag-surface-only smoke is the contract here (cert-manager's
# test.sh set the precedent): "in-cluster" proves flags parsed, cobra wired,
# and the controller-runtime manager got as far as loading kube config.
docker run --rm --entrypoint /usr/bin/external-secrets "$IMAGE" 2>&1 \
  | grep -q "in-cluster" || fail "controller does not reach its API-server step"

echo "Testing --version is rejected while dumping the controller flag surface..."
# Upstream has no --version: pflag rejects the unknown flag and dumps the
# whole surface on the way out; the controller's unique flag must be in it,
# proving this is the manager binary (same trick as flux's test.sh).
out=$(docker run --rm --entrypoint /usr/bin/external-secrets "$IMAGE" --version 2>&1 || true)
echo "$out" | grep -q "unknown flag" || fail "--version was accepted: upstream gained a version flag — revisit this test"
echo "$out" | grep -q -- "--controller-class" || fail "controller flag surface lacks --controller-class"

echo "Testing --help lists the webhook and certcontroller subcommands..."
docker run --rm --entrypoint /usr/bin/external-secrets "$IMAGE" --help 2>&1 \
  | grep -Eq "^\s+certcontroller" || fail "--help missing certcontroller subcommand"
docker run --rm --entrypoint /usr/bin/external-secrets "$IMAGE" --help 2>&1 \
  | grep -Eq "^\s+webhook" || fail "--help missing webhook subcommand"

echo "Testing webhook subcommand surface (the chart runs: external-secrets webhook --port=… )..."
docker run --rm --entrypoint /usr/bin/external-secrets "$IMAGE" webhook --version 2>&1 \
  | grep -q -- "--dns-name" || fail "webhook flag surface lacks --dns-name"

echo "Testing certcontroller subcommand surface..."
docker run --rm --entrypoint /usr/bin/external-secrets "$IMAGE" certcontroller --version 2>&1 \
  | grep -q -- "--service-name" || fail "certcontroller flag surface lacks --service-name"

echo "All external-secrets tests passed!"
