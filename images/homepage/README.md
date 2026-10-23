# homepage

[Homepage](https://github.com/gethomepage/homepage) (the gethomepage.dev
self-hosted services dashboard) built from the pinned release tarball by
melange — `pnpm install` + `next build` with Next's `standalone` output,
mirroring the upstream Dockerfile — and served by Wolfi's `nodejs-24` running
`node server.js`, no Dockerfile. Mirrors the upstream image contract: app at
`/app`, config at `/app/config`, `PORT` (default 3000) / `HOSTNAME` dual-stack
bind probe, `PUID`/`PGID` drop when started as root, and the ping widget's
`iputils` dependency.

```
docker run -d -p 3000:3000 -v homepage-config:/app/config \
  ghcr.io/tylerobara/containers/homepage:latest
```

Tags follow the upstream release: `2.6.0`, `2.6`, `latest`.

## Config

Everything the app reads lives under `/app/config` (`settings.yaml`,
`services.yaml`, `widgets.yaml`, `bookmarks.yaml`, …, plus `logs/` for
winston). Out of the box the package ships `src/skeleton` so the app
self-seeds `settings.yaml` and boots with an empty config; mount a volume (or
bind mount) at `/app/config` to take ownership.

The default user is nonroot **65532** (`homepage`), so a mounted volume must
be writable by uid 65532 — k8s `securityContext: { fsGroup: 65532 }`, or
start once as root (`--user 0 -e PUID=65532 -e PGID=65532`) and the entrypoint
chowns it, drops via `su-exec`, and runs setup the way upstream's PUID/PGID
contract does.

## Deliberate deviations from upstream

- **node 24, not 22**: Wolfi ships node streams 24 + 26; the build pins
  `nodejs-24` (the older stream) and the apko runtime matches it exactly
  instead of following upstream's `node:22-alpine`.
- **Wolfi pnpm, not corepack `pnpm@latest`**: the build installs
  `pnpm-12`/`npm-12` from Wolfi at explicit package names so the toolchain is
  pinned and reproducible (the repo ships a lockfileVersion 9.0 lockfile and
  no `packageManager` field, so nothing fights the pin).
- **Nonroot by default**: upstream defaults to root and drops only when given
  `PUID`/`PGID`; here `run-as: 65532` is the default and the root-drop path is
  kept for compatibility.
- **Self-seeding config**: the image ships `src/skeleton` (standalone tracing
  drops `src/`), so a first boot with an empty config renders the dashboard
  instead of exiting like upstream does until you mount one.
- The port is plain `$PORT` semantics — apko has no `EXPOSE` fields; the
  server binds `$HOSTNAME` (dual-stack `::` with an IPv4 fallback probe, and
  under docker the injected container hostname), so reach it via published
  ports on any interface.
- Requests are host-validated by the app itself (upstream): access via any
  host/port beyond `localhost:3000` needs `HOMEPAGE_ALLOWED_HOSTS` (`*` or a
  comma list), same as upstream's image.

## Signing

Same keyless policy as every image here: signed only when the CI grype scan
reports 0 findings Low+; verify per the command on
<https://tylerobara.github.io/containers/>.

## Updating

`version` + `vars.sha256` in `melange/homepage.yaml` (the tarball URL is
derived from it —
`https://github.com/gethomepage/homepage/archive/refs/tags/v<version>.tar.gz`).
The update-versions bot opens bump PRs against
[gethomepage/homepage releases](https://github.com/gethomepage/homepage/releases).
