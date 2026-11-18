#!/usr/bin/env bash
# Smoke test for the authentik image.
# Usage: IMAGE=ghcr.io/tylerobara/containers/authentik:2026.8.5 ./test.sh
set -euo pipefail

IMAGE="${IMAGE:?set IMAGE=...}"
pass=0
fails=()
check() { # <label> <cmd...>
  local label=$1; shift
  if "$@" >/dev/null 2>&1; then pass=$((pass + 1)); else fails+=("$label"); fi
}

PY=/ak-root/.venv/bin/python

# 1. The venv imports the native-heavy locked deps (psycopg/xmlsec/
#    kadmin_rs/geoip2 link against the shipped Wolfi libs; a missing
#    libsoname fails here, not in a customer's worker).
check "venv imports (django/psycopg/xmlsec/kadmin_rs/geoip2/ldap3)" \
  docker run --rm --entrypoint "$PY" "$IMAGE" -c \
  "import django, psycopg, xmlsec, kadmin_rs, geoip2, ldap3, rest_framework"

# 2. The exact config probe `ak` runs at startup (imports authentik.lib
#    from the shipped source tree, cwd=/).
check "ak startup config probe" \
  docker run --rm --entrypoint "$PY" "$IMAGE" -m authentik.lib.config debugger

# 3. Rust core binary (what ak execs for server/worker) is runnable.
check "authentik core binary --help" \
  docker run --rm --entrypoint /bin/authentik "$IMAGE" --help

# 4. Upstream final-image layout: UI bundle, kerberos config, symlinks.
check "web dist + krb5 + package symlinks" \
  docker run --rm --entrypoint sh "$IMAGE" -c \
  "find /web/dist -name index.html | grep -q . && test -f /etc/krb5.conf \
   && [ \"\$(readlink /packages)\" = /ak-root/packages ] \
   && [ \"\$(readlink /data/media)\" = /media ] && test -d /geoip"

# 5. The ak entrypoint script parses under bash (its pipefail needs it).
check "ak script syntax" \
  docker run --rm --entrypoint bash "$IMAGE" -n /lifecycle/ak

# 6. No apk tooling shipped (prod images are busybox-only).
check "no apk" \
  docker run --rm --entrypoint sh "$IMAGE" -c "! command -v apk"

# 7. Upstream contract: ENTRYPOINT array, CMD, user, env.
EP="$(docker inspect "$IMAGE" --format '{{join .Config.Entrypoint " "}}')"
[ "$EP" = "/usr/bin/dumb-init -- /lifecycle/ak" ] || { echo "entrypoint: got '$EP'"; exit 1; }
pass=$((pass + 1))
CM="$(docker inspect "$IMAGE" --format '{{join .Config.Cmd " "}}')"
[ "$CM" = "server" ] || { echo "cmd: got '$CM'"; exit 1; }
pass=$((pass + 1))
USER="$(docker inspect "$IMAGE" --format '{{.Config.User}}')"
[ "$USER" = "1000" ] || { echo "user: got '$USER'"; exit 1; }
pass=$((pass + 1))
docker inspect "$IMAGE" --format '{{range .Config.Env}}{{println .}}{{end}}' \
  | grep -qx "PATH=/ak-root/.venv/bin:/lifecycle:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" \
  || { echo "PATH missing venv+lifecycle"; exit 1; }
pass=$((pass + 1))

echo "authentik: $pass checks passed"
[ ${#fails[@]} -eq 0 ] || { echo "FAILED: ${fails[*]}"; exit 1; }
