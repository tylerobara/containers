# containers

CloudNativePG-compatible images built the Chainguard way — binaries compiled
from upstream source by [melange](https://github.com/chainguard-dev/melange),
images assembled by [apko](https://github.com/chainguard-dev/apko) on a Wolfi
base. **No Dockerfiles anywhere.**

| Image | Registry | Source |
|---|---|---|
| PostgreSQL 15–18 (PGDG source) | `ghcr.io/tylerobara/containers/cnpg-postgres` | [`images/cloudnative-pg/`](images/cloudnative-pg/) |
| CloudNativePG operator | `ghcr.io/tylerobara/containers/cloudnative-pg` | [`images/cloudnative-pg-operator/`](images/cloudnative-pg-operator/) |
| OpenBao | `ghcr.io/tylerobara/containers/openbao` | [`images/openbao/`](images/openbao/) |

Catalog + grype scan results: <https://tylerobara.github.io/containers/>
(includes a sha-pinned `ClusterImageCatalog` for CNPG, copy-paste `docker pull`
/ `cosign verify` commands, and a filter box).

## CI

`cloudnative-pg.yml` builds everything: a `detect-changes` job generates the
matrix from the repo contents and the event's diff, so a bump PR/push rebuilds
**only the image whose melange config moved**; the daily schedule rebuilds
everything (fresh Wolfi CVE patches). Publish → smoke test → grype → cosign
keyless sign **only when the scan has 0 findings Low or above**. PRs run the
whole pipeline except publish/sign/pages (build, lock guard, local assemble,
smoke test, scan) — see `lint.yml` and `update-versions.yml` alongside it.

## Version updates

The **update-versions** workflow checks upstream daily (PGDG ftp for each
tracked `postgresql-<major>`, GitHub releases for the operator and openbao) and
opens a PR
bumping `version` + `vars.sha256` in the melange config. Review the PR, then:

1. *(optional pre-merge check)* Run **cloudnative-pg.yml** manually with
   `ref = <bump branch>` and **validate_only** checked — builds + scans the
   branch without publishing anything. (Needed because GITHUB_TOKEN-authored
   PRs don't run checks automatically; a GitHub App fixes that if it gets
   annoying.)
2. Merge. The push to main rebuilds and republishes just that image, rescans,
   resigns if clean, and updates the catalog entry in place.

Manual bumps work the same way — just edit `version` + `vars.sha256` yourself.

## Adding an image

Drop a directory at `images/<name>/` with `melange/*.yaml`, `apko/*.yaml` and
`test.sh`, plus build/publish jobs following the `build-operator` pattern in
`cloudnative-pg.yml` (matrix legs run native per-arch runners; keep the
`epoch: 100` + version-guard convention so a Wolfi same-version package can
never win resolution). Postgres majors are detected from the melange config
filenames — adding `postgresql-19.yaml` alone slots it into every matrix.
