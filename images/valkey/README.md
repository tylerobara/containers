# valkey

[Valkey](https://valkey.io) (the Redis-compatible key-value store fork) built
from the upstream release tarball by melange, assembled by apko on Wolfi — no
Dockerfile. Drop-in for the official `valkey/valkey` container
([valkey-io/valkey-container](https://github.com/valkey-io/valkey-container)):
tini + `docker-entrypoint.sh` supervising `valkey-server`, `valkey` user
uid/gid **999**, data dir `/data`, port **6379**.

```
docker run -d --name valkey -v $PWD/data:/data \
  ghcr.io/tylerobara/containers/valkey:latest
docker exec -it valkey valkey-cli ping   # PONG
```

## Startup

Same contract as the upstream container:

- Entrypoint `/sbin/tini -- /usr/bin/docker-entrypoint.sh`, default args
  `valkey-server` (apko renders this as entrypoint + top-level `cmd`).
- The entrypoint (upstream's `docker-entrypoint.sh`, shipped inside the
  melange package) prepends `valkey-server` when your first arg is a `-flag`
  or a `*.conf` path, so `docker run <img> --save ''` and
  `docker run <img> /data/valkey.conf` both boot the server; any other first
  arg execs verbatim (`docker run <img> valkey-cli --help`). `VALKEY_EXTRA_FLAGS`
  is appended to the server command line, like upstream.
- Starts as **root** like the official image: the entrypoint chowns `/data`
  and `su-exec`s down to the `valkey` user (999). A bare `--user <uid>` also
  works because `/data` ships mode 1777 (upstream's own trick for arbitrary
  `--user` runs).
- The entrypoint `cd`s to `/data` — apko has no WORKDIR field — so the
  default `dir ./` and RDB/AOF persistence land in `/data`.

## Differences from valkey/valkey, on purpose

- Wolfi busybox base instead of debian slim (debug shell, no apt at runtime);
  `tzdata` stays (upstream ships it for localtime use), and Wolfi `su-exec`
  replaces the util-linux `setpriv` drop.
- Built with `BUILD_TLS=yes` + the bundled jemalloc/Lua (upstream defaults),
  `USE_SYSTEMD=no` pinned for deterministic linkage — the official image
  links libsystemd for `--supervised systemd`, irrelevant here.
- `protected-mode` is patched off in the source, exactly as the official
  container does (ports are only published explicitly). Put a TLS or firewall
  boundary in front before publishing 6379 publicly.
- The image ships one `valkey` package with the whole `make install` bin/
  layout (server, cli, benchmark, check-rdb/check-aof, sentinel and the
  upstream `redis-*` compat symlinks) — Wolfi splits it into subpackages.

## Signing

Same keyless policy as every image here: signed only when the CI grype scan
reports 0 findings Low+; verify per the command on
<https://tylerobara.github.io/containers/>.

## Updating

`version` + `vars.sha256` in `melange/valkey.yaml` (upstream tags have **no**
`v` prefix; the update-versions bot opens bump PRs). The melange package keeps
`epoch: 100` + `provider-priority: 100` because Wolfi ships `valkey` (≤ 8.1.2)
and `valkey-<series>` packages that publish `provides: valkey=` — ours must
keep winning resolution, and the workflow's lock guard fails loudly if apko
ever resolves a Wolfi build instead of ours (keep the version at or above the
live Wolfi valkey-<series>; the bot bump does that).
