# authentik — goauthentik/authentik minimal image

`ghcr.io/tylerobara/containers/authentik:<version>` (e.g. `2026.8.5`) — a minimal
Wolfi-built drop-in for `ghcr.io/goauthentik/server` (the authentik IDaaS
server: SAML / OIDC / OAuth2 / LDAP). One image serves both roles, exactly
like upstream: `server` (default) or `worker` as the container command.

Built the same way as every image here: **melange** builds from the upstream
release tarball — Angular UI via pnpm, the Rust `authentik` core binary that
`ak` execs, the locked uv venv — and **apko** assembles the image on Wolfi.
No Dockerfile.

## Why from source

No Wolfi package exists; upstream's own image is a fat Debian/FIPS build. We
replicate upstream's final-image recipe (`lifecycle/container/Dockerfile`)
instead, keeping its pins: python 3.14 (`requires-python ==3.14.*`), rust
1.97.1 (Wolfi `rust-1.97`), pnpm 11.20.0 (root `packageManager`), `uv sync
--locked`, `cargo build --locked`.

| Upstream (`ghcr.io/goauthentik/server`) | Ours (Wolfi) |
|---|---|
| fips-python base + `GOFIPS=1` | stock `python-3.14` (no FIPS-validated Wolfi python; non-FIPS is upstream's documented default) |
| `dumb-init -- ak`, `USER 1000`, `PATH=/ak-root/.venv/bin:/lifecycle:...`, `TMPDIR=/dev/shm/` | Same (verified in `test.sh`) |
| `ak server` / `ak worker` / `ak healthcheck` roles | Same; CMD defaults to `server` (upstream relies on compose passing it) |
| GeoIP DBs baked in when a MaxMind key is provided | `/geoip` ships empty — degrades off, same as a license-less upstream build |
| `/tests` tree for the debug path | Not shipped |
| kerberos tuning baked as `/etc/krb5.conf` | Same file at `/etc/authentik-krb5.conf`, selected via `KRB5_CONFIG` (Wolfi's `krb5-conf` owns the default path) |

No `HEALTHCHECK` (apko has none): run `docker exec <c> ak healthcheck` or use
it as a liveness command.

## Usage

Drop-in for upstream's docker-compose: point `image:` here and keep
`command: server` / `command: worker` on the two services. Same env contract
(`AUTHENTIK_SECRET_KEY`, `AUTHENTIK_POSTGRESQL__*`, `AUTHENTIK_REDIS__*`);
`/data` and `/media` need to be writable by UID 1000.

## Verify provenance

```bash
cosign verify \
  --certificate-identity-regexp '^https://github.com/tylerobara/containers/\.github/workflows/authentik\.yml@' \
  --certificate-oidc-issuer-regexp '^https://token\.actions\.githubusercontent\.com$' \
  ghcr.io/tylerobara/containers/authentik:2026.8.5
```

## Testing / local build

```bash
IMAGE=ghcr.io/tylerobara/containers/authentik:2026.8.5 ./test.sh
```

CI runs the same file plus a grype gate (any **Low or higher** finding blocks
publish + signing). To build locally:

```bash
melange build images/authentik/melange/authentik.yaml --arch host
melange publish images/authentik/melange/authentik.yaml --local --archive-not-found=error --signing-key melange.rsa
cgr.dev/chainguard/apko publish --local --repository packages images/authentik/apko/authentik.yaml \
  ghcr.io/tylerobara/containers/authentik:$(awk '/^  version:/{print $2; exit}' images/authentik/melange/authentik.yaml)-amd64
```

## Version bumps

The update-versions bot tracks `version/<x.y.z>` releases; the melange
tarball sha is verified per build, so a stale pin fails loudly rather than
shipping the wrong bytes.
