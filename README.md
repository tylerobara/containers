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
| os-shell (bitnami os-shell counterpart) | `ghcr.io/tylerobara/containers/os-shell` | [`images/os-shell/`](images/os-shell/) |
| DokuWiki | `ghcr.io/tylerobara/containers/dokuwiki` | [`images/dokuwiki/`](images/dokuwiki/) |
| Grafana Image Renderer | `ghcr.io/tylerobara/containers/grafana-image-renderer` | [`images/grafana-image-renderer/`](images/grafana-image-renderer/) |
| Cilium (cilium, cilium-operator-generic, cilium-envoy) | `ghcr.io/tylerobara/containers/cilium` (+ `-operator-generic`, `-envoy`) | [`images/cilium/`](images/cilium/) |
| cert-manager (controller, cainjector, webhook) | `ghcr.io/tylerobara/containers/cert-manager-controller` (+ `-cainjector`, `-webhook`) | [`images/cert-manager/`](images/cert-manager/) |
| MetalLB (controller, speaker, frr-k8s) | `ghcr.io/tylerobara/containers/metallb-controller` (+ `-speaker`, `-frr-k8s`) | [`images/metallb/`](images/metallb/) |
| k8s-sidecar (Grafana dashboards sidecar) | `ghcr.io/tylerobara/containers/k8s-sidecar` | [`images/k8s-sidecar/`](images/k8s-sidecar/) |
| Homepage | `ghcr.io/tylerobara/containers/homepage` | [`images/homepage/`](images/homepage/) |
| Local Path Provisioner | `ghcr.io/tylerobara/containers/local-path-provisioner` | [`images/local-path-provisioner/`](images/local-path-provisioner/) |
| Gatus | `ghcr.io/tylerobara/containers/gatus` | [`images/gatus/`](images/gatus/) |
| Kubernetes Reflector | `ghcr.io/tylerobara/containers/kubernetes-reflector` | [`images/kubernetes-reflector/`](images/kubernetes-reflector/) |
| Dozzle | `ghcr.io/tylerobara/containers/dozzle` | [`images/dozzle/`](images/dozzle/) |

Catalog + grype scan results: <https://tylerobara.github.io/containers/> — an
Astro site (`site/`) with a page per image (specs, tags, advisories, cosign
verify commands), a sha-pinned `ClusterImageCatalog` for CNPG, and the raw
build/scan data at `data/index.json`. See [`site/README.md`](site/README.md).

## CI

One workflow per image family — `postgres.yml`, `cloudnative-pg-operator.yml`,
`openbao.yml`, `os-shell.yml`, `dokuwiki.yml`, `grafana-image-renderer.yml`, `homepage.yml`, `cilium.yml`, `cert-manager.yml`, `metallb.yml`, `k8s-sidecar.yml`, `local-path-provisioner.yml`, `gatus.yml` — so a change to one image can never rebuild or cancel another.
Routing is the native `on.push.paths` filter: a bump PR/push rebuilds **only
the image whose directory moved**; each workflow's daily schedule rebuilds just
its own image (fresh Wolfi CVE patches), staggered 06:00/06:05/06:10/06:15/06:20/06:25/06:30/06:35/06:40/06:45/07:10/07:15/07:25 UTC.
`openbao.yml`, `os-shell.yml`, `dokuwiki.yml`, `grafana-image-renderer.yml`, `homepage.yml`, `cilium.yml`, `cert-manager.yml`, `metallb.yml`, `k8s-sidecar.yml`, `local-path-provisioner.yml`, `dozzle.yml` — so a change to one image can never rebuild or cancel another.
Routing is the native `on.push.paths` filter: a bump PR/push rebuilds **only
the image whose directory moved**; each workflow's daily schedule rebuilds just
its own image (fresh Wolfi CVE patches), staggered 06:00/06:05/06:10/06:15/06:20/06:25/06:30/06:35/06:40/06:45/06:50/07:25 UTC.
Postgres additionally keeps a `detect-changes` job that turns the diff into its
per-major matrix. Publish → smoke test → grype → cosign keyless sign **only
when the scan has 0 findings Low or above**. The cosign cert identity is each
workflow's own filename (see the verify commands on the Pages catalog). PRs run
the whole pipeline except publish/sign/pages (build, lock guard, local
assemble, smoke test, scan) — see `lint.yml` and `update-versions.yml`
alongside these. Every image workflow's `pages` job calls the reusable
`site.yml`, which merges the run's fresh entries into `data/index.json`,
rebuilds the site and publishes gh-pages; `site.yml` also runs on its own for
`site/**` / `catalog.json` changes (rebuild from the live index, no image
build).

## Version updates

The **update-versions** workflow checks upstream daily (PGDG ftp for each
tracked `postgresql-<major>`, GitHub releases for the operator, openbao,
homepage, dokuwiki, grafana-image-renderer, cilium, cert-manager, frr-k8s,
k8s-sidecar, local-path-provisioner and gatus — cilium-envoy
k8s-sidecar, local-path-provisioner and dozzle — cilium-envoy
follows the pin in cilium's own `images/cilium/Dockerfile`, cert-manager's
three configs share one tarball so they bump together in a single PR, and so
do metallb's controller + speaker (frr-k8s is its own upstream repo with its
own version line)) and
opens a PR
bumping `version` + `vars.sha256` in the melange config. Review the PR, then:

1. *(optional pre-merge check)* Run **that image's workflow** (`postgres.yml` /
   `cloudnative-pg-operator.yml` / `openbao.yml` / `dokuwiki.yml` /
   `grafana-image-renderer.yml` / `cilium.yml` / `cert-manager.yml` /
   `metallb.yml` / `k8s-sidecar.yml` / `local-path-provisioner.yml` / `gatus.yml` / `homepage.yml`) manually with
   `metallb.yml` / `k8s-sidecar.yml` / `local-path-provisioner.yml` / `dozzle.yml`) manually with
   `ref = <bump branch>` and **validate_only** checked — builds + scans the
   branch without publishing anything. (Needed because GITHUB_TOKEN-authored
   PRs don't run checks automatically; a GitHub App fixes that if it gets
   annoying.)
2. Merge. The push to main rebuilds and republishes just that image, rescans,
   resigns if clean, and updates the catalog entry in place.

Manual bumps work the same way — just edit `version` + `vars.sha256` yourself.

## Adding an image

Add the image to [`catalog.json`](catalog.json) (name, category, apko file,
summary) so it gets a page on the site, then drop a directory at `images/<name>/` with `melange/*.yaml`, `apko/*.yaml` and
`test.sh`, and clone `.github/workflows/openbao.yml` — the thinnest complete
example (keygen → melange per-arch → apko lock guard + publish → test → grype
→ cosign → Pages merge) — adjusting the trigger paths, artifact names, package
and image name (matrix legs run native per-arch runners; keep the
`epoch: 100` + version-guard convention so a Wolfi same-version package can
never win resolution). Postgres majors are detected from the melange config
filenames — adding `postgresql-19.yaml` alone slots it into every matrix.
An image with nothing to compile from source (like `os-shell`, pure Wolfi
packages) skips melange/keygen entirely: clone `os-shell.yml` instead — one
apko build job, version from `VERSION`, tag = image version.
