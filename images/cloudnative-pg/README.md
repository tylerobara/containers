# cloudnative-pg

CloudNativePG-compatible PostgreSQL images built the same way as
[rtvkiz/minimal](https://github.com/rtvkiz/minimal/tree/main/images/postgres-slim)
`images/postgres-slim`: **apko + Wolfi packages, no Dockerfile**. The package set
mirrors the `minimal` target of the
[CNPG Dockerfile](https://github.com/cloudnative-pg/postgres-containers/raw/refs/heads/main/Dockerfile)
(ldap/sasl auth libs, ca-certificates, PGDG-postgres-equivalent tooling) on
Wolfi's CVE-patched packages.

CNPG contract covered (see [image requirements](https://cloudnative-pg.github.io/docs/container_images/)):

- `initdb`, `postgres`, `pg_ctl`, `pg_controldata`, `pg_basebackup` on PATH, plus
  `pg_rewind`, `pg_isready`, `psql` and friends the instance manager execs
- `du` and the shell applets the instance manager shells out to — busybox only
- uid/gid **26** (CNPG convention, not Wolfi's 70), `run-as: 26`
- `LANG=en_US.UTF-8`; tag starts with the PG major so operator auto-detection works
- No barman: native barman-cloud support is deprecated in CNPG 1.26 in favour of
  the Barman Cloud Plugin, which ships its own sidecar image

## Build

Runs apko's official container so the Linux build pipelines work on macOS too:

```sh
docker run --rm --user root \
  -v "$PWD/images/cloudnative-pg/apko:/apko:ro" \
  -v /var/run/docker.sock:/var/run/docker.sock \
  cgr.dev/chainguard/apko publish \
  /apko/postgresql-minimal.yaml cnpg-postgresql:18.6-minimal \
  --arch aarch64 --local
```

Drop `--arch` to build both `x86_64` + `aarch64` from the config for a push.

## Test

```sh
IMAGE=cnpg-postgresql:18.6-minimal ./test.sh
```

Checks the CNPG tag convention, required binaries, initdb-against-empty-volume
(needs `/bin/sh`), a real server boot + query, uid 26, and prod restraint
(no bash, no apk-tools).

## Not included (add when needed)

- `-dev` variant (bash, apk-tools, gosu, curl, socat, jq) — copy the pattern from
  the minimal repo's `postgres-slim-dev.yaml`
- `postgresql-18-contrib` / `pgaudit-18` / `pgvector-18` — CNPG `standard` equivalents,
  one line each in `contents.packages`
