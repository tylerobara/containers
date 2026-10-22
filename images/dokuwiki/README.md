# dokuwiki

[DokuWiki](https://www.dokuwiki.org/) (standards-compliant plain-file wiki)
assembled from the pinned official release tarball by melange, running on
Wolfi's `apache2` + `php-8.4-apache` (mod_php, prefork), no Dockerfile.
Mirrors the [upstream image](https://github.com/dokuwiki/docker) contract:
`/var/www/html` docroot with read-only `*.core` trees, the `/storage` volume
for `conf/`, `data/`, `lib/plugins`, `lib/tpl`, port 8080, `/health.php`, and
the `PHP_UPLOADLIMIT`/`PHP_MEMORYLIMIT`/`PHP_TIMEZONE` envs.

```
docker run -d -p 8080:8080 -v dokuwiki-storage:/storage \
  ghcr.io/tylerobara/containers/dokuwiki:latest
```

Tags use the apk-safe form of the release date: `2026.07.14c` == upstream's
`2026-07-14c "Mort"`.

## State model (same as upstream)

Everything writable lives under `/storage`; the entrypoint seeds it from the
read-only core trees on every boot (idempotent) and symlinks core extensions
into it. The `install.php` web installer works on first boot; the upgrade
plugin is disabled (you upgrade by bumping the image tag).

`/storage` must be writable by uid 33. Two supported paths:

- **k8s**: `securityContext: { fsGroup: 33 }` on the Pod (image defaults to
  nonroot 33:33; also set `runAsNonRoot: true` to make sure of it).
- **docker / root**: start the container as root (`--user 0` or omit a
  nonroot runAs) and the entrypoint chowns the volume, runs setup as
  www-data, then lets Apache's `User/Group` directives drop the request
  workers to 33 — upstream's exact model, since the master must own the log
  stream anyway.

## Deliberate deviations from upstream

- Vanilla Wolfi `apache2` instead of Debian's `php-*-apache`: no
  `a2enmod`/`a2enconf`, so the whole server config is one self-contained file
  at `/etc/apache2/dokuwiki/httpd.conf`, launched with
  `httpd -d / -f … -DNO_DETACH`.
- No `mod_xsendfile`/`imagemagick` (not packaged by Wolfi): media streams
  through `fetch.php` and GD handles image manipulation, so the
  `xsendfile`/`im_convert` config lines are dropped from the docker config
  overlay.
- Access/error logs are plain files under `/var/log/apache2` forwarded to the
  container log stream by `tail -F` in the entrypoint — this apache build
  loses writes to `/dev/std*` directives and piped logs (verified empirically;
  file logs + inherited-fd forwarding work in both root and nonroot modes).

## Signing

Same keyless policy as every image here: signed only when the CI grype scan
reports 0 findings Low+; verify per the command on
<https://tylerobara.github.io/containers/>.

## Updating

`version` + `vars.sha256` in `melange/dokuwiki.yaml` (release date in dotted
form; the tarball URL is re-dashed from it —
`https://download.dokuwiki.org/src/dokuwiki/dokuwiki-<dashed>.tgz`). The
update-versions bot opens bump PRs against
[dokuwiki/dokuwiki releases](https://github.com/dokuwiki/dokuwiki/releases).
