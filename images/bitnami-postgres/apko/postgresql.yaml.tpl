# Bitnami-compatible PostgreSQL image — PGDG source compiled by melange into
# the Bitnami OSS layout (/opt/bitnami/postgresql), assembled by apko on Wolfi.
# No Dockerfile; the Bitnami script tree ships sha-pinned from the legacy
# (pre-BSI) bitnami/containers definition. See ../README.md for the contract
# and deviations.
#
# Template: @@MAJOR@@ is replaced with the PostgreSQL major (15|16|17|18) by
# the build workflow. libicu78/icu78-data-full track Wolfi's current ICU; all
# postgres majors there link the same ICU.
#
# Bitnami image contract (mirrored from bitnami/containers bitnami/postgresql):
#   - entrypoint /opt/bitnami/scripts/postgresql/entrypoint.sh + CMD run.sh
#   - uid/gid 1001:1001 (postgres), volume at /bitnami/postgresql
#   - /docker-entrypoint-initdb.d + /docker-entrypoint-preinitdb.d
#   - conf.default/ copied over conf/ at boot; logs symlinked to stdout
#   - POSTGRES_* / POSTGRESQL_* env suite, shared_preload_libraries=pgaudit
#   - image tags start with the PG major (e.g. 18.6); :latest from the highest
#     major leg

contents:
  repositories:
    - https://packages.wolfi.dev/os
  keyring:
    - https://packages.wolfi.dev/os/wolfi-signing.rsa.pub
  packages:
    # Base filesystem
    - wolfi-baselayout

    # Shell + coreutils applets: the bitnami scripts run under /bin/sh (via
    # setup.sh/run.sh chains), and busybox supplies id/cut/find/sort/ln/mktemp
    # the libs shell out to.
    - busybox

    # The bitnami script tree is #!/bin/bash (libpostgresql.sh uses arrays,
    # [[ ]], mapfile) — bash is REQUIRED, not convenience.
    - bash

    # getent: postgresql_enable_nss_wrapper probes `getent passwd $(id -u)` on
    # every entrypoint run (guard short-circuits to no-op since 1001 is in
    # /etc/passwd and NSS_WRAPPER_LIB does not exist — but the binary must
    # exist). glibc tools land via posix-libc-utils.
    - posix-libc-utils

    # useradd/groupadd/getent helpers: only exercised on the root-mode paths
    # (setup.sh ensure_user_exists when run as root, matching upstream
    # behaviour); non-root runs never touch them.
    - shadow

    # PostgreSQL built from PGDG source by melange (see ../melange/) in the
    # Bitnami /opt layout, PLUS the Bitnami script tree baked into the same
    # package (scripts/, conf.default/, run-script, hostname shim). One fat
    # package ships server + client + libpq at the current PGDG minor
    # (15.19/16.15/17.11/18.6). provider-priority: 100 + epoch 100 make apko
    # pick it over Wolfi's same-named package. Runtime .so deps are recorded
    # by melange and resolve against Wolfi automatically.
    - postgresql-@@MAJOR@@

    # repmgr + pgaudit for this major, built by us into the /opt layout
    # (wolfi's extension packages live in /usr/lib/postgresql@@MAJOR@@,
    # unloadable by this server; wolfi only ships them for 18 anyway).
    # provider-priority + epoch win the 5.5.0/18.0 ties against wolfi repmgr-18/pgaudit-18.
    - repmgr-@@MAJOR@@
    - pgaudit-@@MAJOR@@

    # Core libraries
    - glibc
    - glibc-locale-posix
    - glibc-locale-en
    - ld-linux
    - libgcc
    - libstdc++
    - libcrypt1
    - libxcrypt

    # SSL/TLS runtime — NOT pinned here on purpose: the melange build links
    # whichever OpenSSL is current in Wolfi and records the exact so:
    # dependency, which apko resolves to the right runtime package.

    # ICU (internationalization)
    - libicu78
    - icu78-data-full

    # Authentication/security libraries — the binary is built --with-ldap
    # --with-gssapi --with-pam like upstream's; these are the runtime equivs
    # (bitnami's image ships the same set from debian).
    - cyrus-sasl
    - heimdal-libs
    - krb5-libs
    - krb5-conf
    - keyutils-libs
    - libldap-2.6
    - libverto
    - linux-pam
    - libselinux
    - libsepol

    # XML/XSLT
    - libxml2-16
    - libxslt

    # Compression (WAL compression, basebackup)
    - liblz4-1
    - libzstd1
    - zlib

    # Database/utility libraries
    - libedit
    - libffi
    - libpcre2-8-0
    - libuuid
    - libcom_err

    # Terminal
    - ncurses
    - ncurses-terminfo-base
    - readline

    # Locale and timezone
    - localedef
    - tzdata

    # Certificates
    - ca-certificates-bundle

accounts:
  groups:
    - groupname: postgres
      gid: 1001
  users:
    - username: postgres
      uid: 1001
      gid: 1001
      shell: /bin/bash
      homedir: /bitnami/postgresql
  run-as: 1001

entrypoint:
  command: /opt/bitnami/scripts/postgresql/entrypoint.sh

# apko has no entrypoint.args — the top-level cmd is the image CMD. run.sh is
# what bitnami's Dockerfile sets, and entrypoint.sh keys off it (it runs
# setup.sh when the args contain run.sh), so the chart contract needs it.
cmd: /opt/bitnami/scripts/postgresql/run.sh

environment:
  # postgresql-env.sh re-prepends /opt/bitnami/postgresql/bin and
  # /opt/bitnami/common/bin once sourced; the base PATH still has to find
  # busybox applets + bash + getent before that.
  PATH: /opt/bitnami/postgresql/bin:/opt/bitnami/common/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
  LD_LIBRARY_PATH: /opt/bitnami/postgresql/lib
  LANG: en_US.UTF-8
  BITNAMI_DEBUG: "false"
  HOME: /

paths:
  # Mutable tree for the 1001 runtime user (bitnami's own postunpack already
  # chmod'd g+rwX in the package; ownership comes from apko here).
  - path: /opt/bitnami/postgresql/conf
    type: directory
    uid: 1001
    gid: 1001
    permissions: 0o775
  - path: /opt/bitnami/postgresql/conf/conf.d
    type: directory
    uid: 1001
    gid: 1001
    permissions: 0o775
  - path: /opt/bitnami/postgresql/logs
    type: directory
    uid: 1001
    gid: 1001
    permissions: 0o775
  - path: /opt/bitnami/postgresql/tmp
    type: directory
    uid: 1001
    gid: 1001
    permissions: 0o775
  - path: /bitnami/postgresql
    type: directory
    uid: 1001
    gid: 1001
    permissions: 0o775
  # initdb.d scripts are mounted read-only by callers; 1001 ownership matches
  # postunpack's g+rwX intent.
  - path: /docker-entrypoint-initdb.d
    type: directory
    uid: 1001
    gid: 1001
    permissions: 0o775
  - path: /docker-entrypoint-preinitdb.d
    type: directory
    uid: 1001
    gid: 1001
    permissions: 0o775

annotations:
  org.opencontainers.image.title: "bitnami-compatible-postgres"
  org.opencontainers.image.description: "Bitnami-compatible PostgreSQL image: PGDG source, sha-pinned Bitnami scripts, Wolfi CVE patches"
  org.opencontainers.image.url: "https://github.com/tylerobara/containers"
  org.opencontainers.image.source: "https://github.com/tylerobara/containers/tree/main/images/bitnami-postgres"
  org.opencontainers.image.licenses: "Apache-2.0"
  io.bitnami.compat: "legacy-debian-12"

archs:
  - x86_64
  - aarch64
