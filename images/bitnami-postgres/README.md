# bitnami-postgres

Bitnami-compatible PostgreSQL 15–18 for the Bitnami chart contract — PGDG
source compiled by melange into the Bitnami OSS layout (`/opt/bitnami/…`),
the Bitnami script tree shipped **sha-pinned from the legacy (pre-BSI)
`bitnami/containers` definition**, assembled by apko on Wolfi. No Dockerfile.

| | |
|---|---|
| Image | `ghcr.io/tylerobara/containers/bitnami-postgres` |
| Tags | `<major>`, `<major.minor>`, `<major>-wolfi`, `<minor>-wolfi`; `latest` from the highest-major leg |
| Build | melange `v0.63.0` + apko (`cgr.dev/chainguard/apko`), Wolfi, `x86_64` + `aarch64` |
| Workflow | [`.github/workflows/bitnami-postgres.yml`](../../.github/workflows/bitnami-postgres.yml) (daily `45 7 * * *`) |
| Sign | cosign keyless, identity `…/workflows/bitnami-postgres.yml@refs/heads/main` |

## What ships

Built per major (15, 16, 17, 18) as three melange packages assembled into one
image by [apko/postgresql.yaml.tpl](apko/postgresql.yaml.tpl):

- **`postgresql-<major>`** — PGDG tarball, `--prefix=/opt/bitnami/postgresql`
  (same `--with-*` feature set as the CloudNativePG family), plus the pinned
  Bitnami script tree extracted into `/opt/bitnami/scripts`, `/usr/sbin/run-script`,
  and Bitnami's own `postunpack.sh` **executed unmodified at build time** (it
  generates `conf.default/` — `postgresql.conf` from the `$(datadir)` sample
  with `include_dir`, trust `pg_hba.conf` — creates `logs/`/`tmp/`, symlinks
  logs to stdout, `chmod g+rwX`). `melange` pipelines run as root here, which
  is what lets the upstream scripts run verbatim against the real `/opt`.
- **`repmgr-<major>`** — repmgr 5.5.0 via PGXS against Wolfi's
  `postgresql-<major>-dev`; binaries in `/opt/bitnami/repmgr/bin`,
  `repmgr.so`/extension files in the `/opt` server's dirs.
- **`pgaudit-<major>`** — pgaudit (per-major version from the upstream
  compat table) the same way, so the scripts' default
  `SHARED_PRELOAD_LIBRARIES=pgaudit` preloads.

## Provenance pins

| PG major | PGDG | Bitnami script tree (bitnami/containers commit) | tarball sha256 (first 16) |
|---|---|---|---|
| 15 | 15.19 | `e7699df4c94f9182f739df15c56a8959f980000b` | `c18218bb3339cc66…` |
| 16 | 16.15 | `0191828691ccfad53afb58d918ce2dd3105e1f6b` | `3e4d2c6f855f5306…` |
| 17 | 17.11 | `f2675e174c9479e5414428620ae47eefbc1eb213` | `65ac379eac962856…` |
| 18 | 18.6 | `172ef0946b1520af18db2fdf215a2f95d0ddd758` | `be62b7a933ce18d2…` |

Full shas live in each `melange/postgresql-<major>.yaml` (`vars.sha256`,
`vars.bitnami_sha256`); the tree extracted per major is
`bitnami/postgresql/<major>/debian-12/{rootfs,prebuildfs}` (scripts + run-script)
from `https://codeload.github.com/bitnami/containers/tar.gz/<commit>`. Scripts
are never re-implemented or patched — if a fix is ever needed it goes through
a new pinned commit, same as PGDG bumps. The update-versions bot bumps the
PGDG pins (`bitnami-postgresql-<major>` rows); repmgr/pgaudit pins are bumped
by hand against [PGDG](https://www.postgresql.org/support/versioning/),
[repmgr](https://github.com/EnterpriseDB/repmgr/tags) and
[pgaudit](https://github.com/pgaudit/pgaudit/tags).

## Chart contract (what test.sh asserts)

- `ENTRYPOINT /opt/bitnami/scripts/postgresql/entrypoint.sh`, `CMD …/run.sh`
  (apko has no `entrypoint.args`; the top-level `cmd:` is used), `run-as: 1001`
  (`postgres:postgres` 1001:1001 in `/etc/passwd`).
- Volume `/bitnami/postgresql` (`data/` lives under it); mutable dirs owned by
  1001; logs → stdout; `conf.default/` copied over `conf/` at boot.
- `POSTGRES_USER/PASSWORD/DB/POSTGRES_PASSWORD` (+ `POSTGRESQL_*` aliases),
  `ALLOW_EMPTY_PASSWORD=yes`, `/docker-entrypoint-initdb.d` (`.sql` via the
  initscripts user, `.sh` executed if +x else sourced,
  `.user_scripts_initialized` marker) and `/docker-entrypoint-preinitdb.d`.
- `shared_preload_libraries=pgaudit`, `wal_level=replica`, native streaming
  replication via `POSTGRESQL_REPLICATION_MODE` on the pinned script tree.

## Documented deviations (all honest, none silent)

- **repmgr is a compatibility package, not the replication runtime.** The
  pinned legacy script trees use PostgreSQL **native streaming replication**
  (`POSTGRESQL_REPLICATION_MODE` + `postgresql_setup_replication`); repmgr
  appears only in stale comments. We still ship our `/opt`-built repmgr per
  major (`repmgr --version` + `CREATE EXTENSION repmgr` are smoke-tested)
  because Bitnami layouts are expected to have it.
- **pgBackRest / LDAP auth wiring / nss_wrapper / FIPS-BSI extras: skipped.**
  The server binary is still built `--with-ldap` (binary parity), but none of
  the BSI/enterprise script trees (which are where those live) are in scope —
  the issue scopes this to the legacy debian-12 OSS scripts.
- **`hostname` shim.** busybox `hostname` has no `--fqdn` (only `-f`) but
  `postgresql-env.sh` calls `hostname --fqdn` on every source; the package
  ships `/opt/bitnami/common/bin/hostname` mapping it, on the PATH the scripts
  themselves prepend.
- **Wolfi's repmgr/pgaudit packages are unused even for 18**: they install to
  `/usr/lib/postgresql<major>`, unloadable by the `/opt`-prefixed server.
- Root-mode convenience paths (upstream's `run_as_user` → coreutils
  `chroot --userspec`, `useradd`) assume `shadow` (shipped); the tested,
  chart-realistic path is non-root uid 1001.

## Usage

```bash
docker run -d --user 1001 \
  --tmpfs /bitnami/postgresql:uid=1001,gid=1001,mode=0775 \
  -e POSTGRES_USER=app -e POSTGRES_PASSWORD=… -e POSTGRES_DB=app \
  ghcr.io/tylerobara/containers/bitnami-postgres:18.6
```

On Kubernetes, mount the volume at `/bitnami/postgresql` with `fsGroup: 1001`
(and `runAsUser: 1001`, like the Bitnami chart does).

Smoke: `IMAGE=<ref> PG_MAJOR=18 ./test.sh` (run by CI per major).
