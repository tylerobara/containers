# pocket-id (pocket-id, pocket-id-operator)

Pocket ID — the passkey/WebAuthn OIDC provider — and its Kubernetes operator,
built the minimal way: both binaries compiled from their upstream release
tarballs by **melange** with upstream's own build contract, assembled by
**apko** on Wolfi — no Dockerfile anywhere.

| Image | Upstream | Built | Contents |
|---|---|---|---|
| `ghcr.io/tylerobara/containers/pocket-id` | `ghcr.io/pocket-id/pocket-id:<v>-distroless` | melange: pnpm + vite-plus SvelteKit build, then `CGO_ENABLED=0 go build ./cmd` embedding it | `/usr/bin/pocket-id` (frontend embedded), `/app/data` for SQLite/uploads |
| `ghcr.io/tylerobara/containers/pocket-id-operator` | `ghcr.io/aclerici38/pocket-id-operator` | melange: `CGO_ENABLED=0 go build -o manager ./cmd` (kubebuilder / controller-runtime) | `/manager` |

The two images come from **different upstream repos with independent version
lines** (`pocket-id/pocket-id` and `aclerici38/pocket-id-operator`), so they
bump separately — unlike cert-manager's three-config lockstep family, this
workflow's version guard only checks the version *format*, and the
update-versions bot has one row per image.

```
docker run --rm ghcr.io/tylerobara/containers/pocket-id:latest version
# pocket-id 2.18.0
```

## pocket-id

Upstream's `-distroless` image (`docker/Dockerfile-distroless`) is a static Go
binary with the SvelteKit frontend already `//go:embed`-ed
(`backend/frontend/frontend_included.go`), so the melange build has to be two
stages just like upstream's own multi-stage Dockerfile: the pinned `pnpm`
(from the repo's `packageManager` field, fetched by corepack) builds the
frontend into `backend/frontend/dist`, then Go embeds it and stamps
`internal/common.Version` via ldflags — `pocket-id version` reports the real
release, and the melange build fails if it does not.

Tags are the plain version (`2.18.0`, `2.18`, `latest`); upstream's
`v2.18.0-distroless` form is the same artifact set. Pin by digest in
production and verify signatures:

```
cosign verify \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com \
  --certificate-identity-regexp '^https://github\.com/tylerobara/containers/\.github/workflows/pocket-id\.yml@refs/heads/main$' \
  ghcr.io/tylerobara/containers/pocket-id:2.18.0
```

(Only digest-pinned references are signed, and only when the daily grype scan
reports zero Low+ findings — see the Pages catalog for current state.)

### Running it

`docker run` with an encryption key is enough for a first boot (SQLite is pure
Go, so no cgo anywhere):

```
docker run --rm -p 127.0.0.1:1411:1411 \
  -e ENCRYPTION_KEY=<at-least-16-bytes> \
  -e APP_URL=http://localhost:1411 \
  -e DB_CONNECTION_STRING=/app/data/pocket-id.db \
  -v $PWD/data:/app/data \
  ghcr.io/tylerobara/containers/pocket-id:2.18.0
```

The default SQLite path is CWD-relative (`data/pocket-id.db`), so either pass
an absolute `DB_CONNECTION_STRING` (what the upstream chart and the
pocket-id-operator both do — it mounts its PVC at `/app/data`) or run with
`--workdir /app`. `/app/data` ships owned by 65532; a mounted volume needs
`fsGroup: 65532` (or a chown) to be writable.

### Deliberate differences from upstream

- **distroless → busybox-on-Wolfi** base: same single static binary, plus
  `/bin/sh` for debugging and Wolfi `ca-certificates`. Binary lives at
  `/usr/bin/pocket-id`, not `/app/pocket-id`.
- **No `entrypoint.sh`**: upstream's alpine variant only uses it to chown
  `/app/data` and re-exec as `PUID`/`PGID` (needs root + `su-exec`). The
  nonroot 65532 default makes it dead weight, so PUID/PGID are not supported —
  run the container as the uid you want (`--user`) and chown your volume.
- **Baked-in absolute `UPLOAD_PATH` / `GEOLITE_DB_PATH`**: upstream's defaults
  (`data/uploads`, `data/GeoLite2-City.mmdb`) resolve against its
  `WORKDIR /app`; apko has no WORKDIR, so a bare run would mkdir on the
  read-only root. The image env pins both into the same volume as the SQLite
  DB (uploads land in `/app/data/uploads`).
- **`healthcheck` still works** (it is the upstream `HEALTHCHECK` command and
  is covered by `test.sh`).

## pocket-id-operator

Standard kubebuilder manager: upstream's Dockerfile does
`CGO_ENABLED=0 go build -a -o manager cmd/main.go` and copies the result onto
`distroless/static` as `/manager`, running as `65532:65532`. The helm chart
hardcodes `command: [/manager]`, so the path is kept for drop-in chart use:

```
helm upgrade pocket-id-operator oci://ghcr.io/aclerici38/pocket-id-operator/charts/pocket-id-operator \
  --version v0.15.0 \
  --set operator.image.repository=ghcr.io/tylerobara/containers/pocket-id-operator \
  --set operator.image.tag=0.15.0
```

There is no `--version` flag or version ldflag upstream, so the melange build
asserts identity instead: the flag surface of this repo's `cmd/main.go`, the
manager reaching its API-server step, and the module path in the binary's
embedded Go build info (which is also what grype reads).

## Files

- `melange/pocket-id.yaml`, `melange/pocket-id-operator.yaml` — one config per
  binary (own tarball, own `vars.sha256`)
- `apko/pocket-id.yaml`, `apko/pocket-id-operator.yaml` — one config per image
- `test.sh <pocket-id|pocket-id-operator>` — CI smoke test (`IMAGE=… VERSION=…
  ./test.sh pocket-id`); the pocket-id leg boots the server and checks the
  embedded SvelteKit bundle is served
- `.github/workflows/pocket-id.yml` — build/publish/scan/sign, daily 07:05 UTC
