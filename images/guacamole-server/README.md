# guacamole-server

[Apache Guacamole](https://guacamole.apache.org)'s proxy daemon — `guacd`,
`libguac` and all five protocol plugins (**RDP** via FreeRDP 3, **VNC** via
libvncclient, **SSH** via libssh2, **telnet** via libtelnet, **Kubernetes**
via libwebsockets) — built from the sha-pinned upstream release tag by
melange, assembled by apko on Wolfi — no Dockerfile. Drop-in for the official
`guacamole/guacd` container (apache/guacamole-server's own Dockerfile):
tini + `docker-entrypoint.sh` supervising `guacd`, `guacd` user uid/gid
**1000**, port **4822**.

```
docker run -d --name guacd -p 4822:4822 \
  ghcr.io/tylerobara/containers/guacamole-server:latest
docker exec guacd nc -z 127.0.0.1 4822 && echo up
```

Point a [Guacamole web client](https://guacamole.apache.org) (or the Apache
Helm chart's `guacamole` deployment) at `guacd:4822`.

## Startup

Same contract as the upstream container:

- Entrypoint `/sbin/tini -- /usr/bin/docker-entrypoint.sh`, empty default args
  (apko renders this as the entrypoint field + empty `cmd`).
- The entrypoint (upstream's `entrypoint.sh`, shipped inside the melange
  package, path-adapted to `/usr/sbin/guacd`) execs
  `guacd -f -b 0.0.0.0 -L <level>`: log level from `LOG_LEVEL` (the deprecated
  `GUACD_LOG_LEVEL` still works and warns, like upstream), default `info`.
  Extra `docker run` args are appended to the guacd command line verbatim
  (`docker run <img> -L debug`).
- Runs as the **guacd** user (uid/gid 1000), like upstream's `USER guacd` —
  4822 is unprivileged, so no root-start/drop dance. File-transfer drive
  mounts (the Helm chart's `/config/drive` volumes) must be writable by
  uid 1000.

## Differences from guacamole/guacd, on purpose

- Wolfi base with the protocol libraries as **system packages** (FreeRDP 3,
  libvncclient, libtelnet, libwebsockets, ffmpeg, pulseaudio) instead of
  upstream's from-source `/opt/guacamole` stack (which builds FreeRDP 2,
  libvncserver and friends itself) — the approach Wolfi's own
  `guacamole-server` package takes, so CVE patches flow with the daily Wolfi
  rebuild instead of being frozen into a source tree.
- FreeRDP **3** (Wolfi ships it; upstream's Dockerfile still defaults to 2 —
  upstream 1.6.0 supports both).
- tini added as PID 1 (house pattern of every image here): guacd forks one
  worker per connection; tini reaps strays and forwards signals.
- Fonts: `ttf-dejavu` + `font-liberation` + `font-noto-cjk` cover upstream's
  server-side text rendering set; Alpine's `terminus-font` has no Wolfi
  counterpart and the full `font-noto` script family is skipped.
- Built with upstream's container flags (`--disable-guaclog`,
  `-Wno-error=deprecated-declarations`). The SSH **agent** plugin is not
  built: its configure probe requires libssh2 linked against libgcrypt,
  while Wolfi's libssh2 is OpenSSL-based — same as Wolfi's own build.
- The melange build asserts all five `libguac-client-*.so` plugins exist, so
  a renamed/missing Wolfi `-dev` package can never silently drop a protocol.

## Signing

Same keyless policy as every image here: signed only when the CI grype scan
reports 0 findings Low+; verify per the command on
<https://tylerobara.github.io/containers/>.

## Updating

`version` + `vars.sha256` in `melange/guacamole-server.yaml` (upstream
publishes **no GitHub releases** — tags only, plain `X.Y.Z` without a `v`
prefix; the update-versions bot filters the tag list for that shape, which
drops the `-RC` candidates, and opens bump PRs). The melange package keeps
`epoch: 100` + `provider-priority: 100` because Wolfi ships its own
`guacamole-server` (currently 1.6.0-rN, split into `libguac` +
`libguac-client-*`) — ours must keep winning resolution, and the workflow's
lock guard fails loudly if apko ever resolves a Wolfi build instead of ours
(keep the version at or above the live Wolfi version; the bot bump does that).
