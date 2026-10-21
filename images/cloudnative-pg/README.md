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
- `LANG=en_US.UTF-8`; tags start with the PG major so operator auto-detection works
- No barman: native barman-cloud support is deprecated in CNPG 1.26 in favour of
  the Barman Cloud Plugin, which ships its own sidecar image

## Majors & tags

`apko/postgresql.yaml.tpl` is rendered per major (**15, 16, 17, 18**); the exact
`MAJOR.MINOR` comes from the `apko lock` resolution at build time, never from a
hand-maintained number. Each build publishes four tags pointing at one digest:

```
ghcr.io/tylerobara/containers/cnpg-postgres:18        ghcr.io/.../cnpg-postgres:18-wolfi
ghcr.io/tylerobara/containers/cnpg-postgres:18.6      ghcr.io/.../cnpg-postgres:18.6-wolfi
```

## CI/CD (`.github/workflows/cloudnative-pg.yml`)

- **Daily** (`cron 06:00 UTC`) + on pushes touching this directory + manual
  dispatch. Matrix over the majors; `apko lock` pins the build, the published
  tags match the resolved versions.
- **grype** scans each published image; results feed the catalog page.
- **GitHub Pages**: the `pages` job pushes a generated `gh-pages` branch
  (`pages/index.html` + `data/*.json`) — enable it once under
  Settings → Pages → Source: **Deploy from a branch** → `gh-pages` / `(root)`.
  Catalog: https://tylerobara.github.io/containers/
- **ghcr auth**: nested package names (`owner/repo/image`) cannot be created by
  `GITHUB_TOKEN` — add a **`CR_PAT`** repo secret (fine-grained PAT, this repo,
  `packages: Write`; or classic with `write:packages`).

## Build locally

Runs apko's official container so the Linux build pipelines work on macOS too:

```sh
MAJOR=18
mkdir -p build
sed "s/@@MAJOR@@/$MAJOR/g" apko/postgresql.yaml.tpl > "build/postgresql-$MAJOR.yaml"
docker run --rm --user root -v "$PWD/build:/build" \
  cgr.dev/chainguard/apko lock "/build/postgresql-$MAJOR.yaml" \
    --arch aarch64 --output "/build/pg-$MAJOR.lock.json"
docker run --rm --user root -v "$PWD/build:/build:ro" \
  cgr.dev/chainguard/apko publish "/build/postgresql-$MAJOR.yaml" \
    "cnpg-postgres:18-minimal" --arch aarch64 --local --lockfile "/build/pg-$MAJOR.lock.json"
```

## Test

```sh
IMAGE=cnpg-postgres:18-minimal PG_MAJOR=18 ./test.sh
```

Checks the CNPG tag convention, required binaries, initdb-against-empty-volume
(needs `/bin/sh`), a real server boot + query, uid 26, and prod restraint
(no bash, no apk-tools).

## Not included (add when needed)

- `-dev` variant (bash, apk-tools, gosu, curl, socat, jq) — copy the pattern from
  the minimal repo's `postgres-slim-dev.yaml`
- `postgresql-N-contrib` / `pgaudit-N` / `pgvector-N` — CNPG `standard` equivalents,
  one line each in the template's `contents.packages`
