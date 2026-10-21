# cloudnative-pg

CloudNativePG-compatible PostgreSQL images built the same way as
[rtvkiz/minimal](https://github.com/rtvkiz/minimal/tree/main/images/postgres-slim)
`images/postgres-slim`: **apko + Wolfi base, no Dockerfile**. The package set
mirrors the `minimal` target of the
[CNPG Dockerfile](https://github.com/cloudnative-pg/postgres-containers/raw/refs/heads/main/Dockerfile)
(ldap/sasl auth libs, ca-certificates, PGDG-postgres-equivalent tooling) on
Wolfi's CVE-patched packages.

PostgreSQL itself is **built from PGDG source by melange** (`melange/`, the
minimal repo's traefik pattern), not Wolfi's stale prebuilds (15.6/16.14/17.10
vs PGDG's 15.19/16.15/17.11). The package is named exactly `postgresql-<major>`
with `provider-priority: 100` so apko picks it over Wolfi's same-named package
and grype/Wolfi-secdb still identify it. One fat package ships server + client
+ libpq. JIT is intentionally not built — it drops the 154 MB `libLLVM` layer
(image ≈ 199 MB vs 388 MB with Wolfi's JIT-enabled build).

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
`MAJOR.MINOR` is the `version:` in `melange/postgresql-<major>.yaml` — the one
source of truth. Each build publishes four tags pointing at one digest:

```
ghcr.io/tylerobara/containers/cnpg-postgres:18        ghcr.io/.../cnpg-postgres:18-wolfi
ghcr.io/tylerobara/containers/cnpg-postgres:18.6      ghcr.io/.../cnpg-postgres:18.6-wolfi
```

The workflow refuses to publish if `apko lock` resolves anything other than the
melange config's version, so tags can never drift from what was built.

**On each PGDG minor release** (e.g. 17.12): bump `version` and `vars.sha256`
(SHA256 of `https://ftp.postgresql.org/pub/source/v<ver>/postgresql-<ver>.tar.bz2`)
in that major's melange config and push — that is the whole update procedure.

## CI/CD (`.github/workflows/cloudnative-pg.yml`)

- **Daily** (`cron 06:00 UTC`) + on pushes touching this directory + manual
  dispatch. Pipeline: `keygen` (ephemeral melange signing key, no repo secrets)
  → `melange` (matrix major × arch, native runners: x86_64 on `ubuntu-latest`,
  aarch64 on `ubuntu-24.04-arm`) → `build` (per major: `apko lock` with the
  melange repo appended, version guard, publish, smoke test) → `pages`.
- apko consumes the melange packages via
  `--repository-append /work/packages --keyring-append /work/melange.rsa.pub`.
- **grype** scans each published image; results feed the catalog page.
- **GitHub Pages**: the `pages` job pushes a generated `gh-pages` branch
  (`pages/index.html` + `data/*.json`) — enable it once under
  Settings → Pages → Source: **Deploy from a branch** → `gh-pages` / `(root)`.
  Catalog: https://tylerobara.github.io/containers/
- **ClusterImageCatalog**: each Pages deploy also emits
  `data/cluster-image-catalog.yaml` — one entry per major, each image pinned to
  the multi-arch manifest digest published that run:

  ```sh
  kubectl apply -f https://tylerobara.github.io/containers/data/cluster-image-catalog.yaml
  # then: spec.imageCatalogRef: { kind: ClusterImageCatalog, name: cnpg-postgres-wolfi }
  ```
- **ghcr auth**: nested package names (`owner/repo/image`) cannot be created by
  `GITHUB_TOKEN` — add a **`CR_PAT`** repo secret (fine-grained PAT, this repo,
  `packages: Write`; or classic with `write:packages`).

## Build locally

Melange builds the packages, then apko's official container assembles the image
(the container makes the Linux pipelines work on macOS too). Melange build
takes ~5 min per major/arch:

```sh
brew install melange  # one-time
MAJOR=17
melange keygen  # once — creates melange.rsa + melange.rsa.pub
melange build "melange/postgresql-$MAJOR.yaml" --arch aarch64 \
  --signing-key melange.rsa --out-dir ./packages --runner docker

mkdir -p build
sed "s/@@MAJOR@@/$MAJOR/g" apko/postgresql.yaml.tpl > "build/postgresql-$MAJOR.yaml"
docker run --rm --user root -v "$PWD:/work" \
  cgr.dev/chainguard/apko lock "/work/build/postgresql-$MAJOR.yaml" \
    --arch aarch64 --repository-append /work/packages \
    --keyring-append /work/melange.rsa.pub --output "/work/build/pg-$MAJOR.lock.json"
docker run --rm --user root -v "$PWD:/work" -v /var/run/docker.sock:/var/run/docker.sock \
  cgr.dev/chainguard/apko publish "/work/build/postgresql-$MAJOR.yaml" \
    "cnpg-postgres:${MAJOR}.11-local" --arch aarch64 --local \
    --lockfile "/work/build/pg-$MAJOR.lock.json" \
    --repository-append /work/packages --keyring-append /work/melange.rsa.pub
```

## Test

```sh
IMAGE=cnpg-postgres:17.11-local PG_MAJOR=17 ./test.sh
```

Checks the CNPG tag convention, required binaries, initdb-against-empty-volume
(needs `/bin/sh`), a real server boot + query, uid 26, and prod restraint
(no bash, no apk-tools).

## Not included (add when needed)

- `-dev` variant (bash, apk-tools, gosu, curl, socat, jq) — copy the pattern from
  the minimal repo's `postgres-slim-dev.yaml`
- `postgresql-N-contrib` / `pgaudit-N` / `pgvector-N` — CNPG `standard` equivalents,
  one line each in the template's `contents.packages`
