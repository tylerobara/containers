#!/usr/bin/env node
// build-data.mjs — assemble the catalog dataset the Astro site renders.
//
// Usage:
//   node scripts/build-data.mjs [index.json]
//
// Reads (all optional except catalog.json):
//   ../catalog.json                     source of truth: image list + metadata
//   ../images/<dir>/apko/<file>         specifications fallback + requested packages
//   <index.json>                        per-image build entries written by the
//                                       image workflows (version, tags, digest,
//                                       signed, full grype scan) — the same
//                                       file published at /data/index.json
//   GHCR registry API (anonymous)       image config (env, entrypoint, user,
//                                       ports), architectures, compressed size
//
// Writes:
//   src/data/images.json                one rich record per page
//
// Each image is assembled in its own try/catch: a missing or corrupt source
// degrades that image (recorded in `dataStatus`/`notes`) but never fails the
// build. The ONLY fatal conditions are an unreadable catalog.json, or an index
// that was given but matched zero catalog images (guards against publishing an
// empty catalog over a good one).

import { readFileSync, existsSync, writeFileSync, mkdirSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join, resolve } from 'node:path';
import { parse as parseYaml } from 'yaml';

const __dirname = dirname(fileURLToPath(import.meta.url));
const SITE_DIR = resolve(__dirname, '..');
const REPO_DIR = resolve(SITE_DIR, '..');
const INDEX_FILE = process.argv[2] ? resolve(process.cwd(), process.argv[2]) : null;
const OUT_FILE = join(SITE_DIR, 'src', 'data', 'images.json');

const SKIP_REGISTRY = process.env.SKIP_REGISTRY === '1' || process.env.SKIP_REGISTRY === 'true';
const FETCH_TIMEOUT_MS = 8000;

const warnings = [];
function warn(msg) { warnings.push(msg); console.warn(`  ! ${msg}`); }

//--- small helpers -----------------------------------------------------------

function readJson(path) {
  return JSON.parse(readFileSync(path, 'utf8'));
}

function humanBytes(b) {
  if (!b || b < 0) return null;
  const units = ['B', 'KB', 'MB', 'GB', 'TB'];
  let i = 0, n = Number(b);
  while (n >= 1024 && i < units.length - 1) { n /= 1024; i++; }
  return `${n.toFixed(n < 10 && i > 0 ? 1 : 0)} ${units[i]}`;
}

function agoFrom(iso) {
  if (!iso) return null;
  const then = Date.parse(iso);
  if (Number.isNaN(then)) return null;
  const days = Math.floor((Date.now() - then) / 86400000);
  if (days <= 0) return 'today';
  if (days === 1) return '1 day ago';
  if (days < 30) return `${days} days ago`;
  const months = Math.floor(days / 30);
  if (months === 1) return '1 month ago';
  if (months < 12) return `${months} months ago`;
  const years = Math.floor(days / 365);
  return years === 1 ? '1 year ago' : `${years} years ago`;
}

async function fetchWithTimeout(url, opts = {}) {
  const ctrl = new AbortController();
  const t = setTimeout(() => ctrl.abort(), FETCH_TIMEOUT_MS);
  try {
    return await fetch(url, { ...opts, signal: ctrl.signal });
  } finally {
    clearTimeout(t);
  }
}

function tryOr(fn, onErr) {
  try { return fn(); } catch (e) { onErr(e); return null; }
}

//--- apko config -> specifications -------------------------------------------

// postgresql.yaml.tpl is a template the postgres workflow renders per major;
// substitute the same placeholder so it parses as the image actually built.
function specsFromApko(path, major) {
  let text = readFileSync(path, 'utf8');
  if (major != null) text = text.replaceAll('@@MAJOR@@', String(major));
  const cfg = parseYaml(text) || {};
  const contents = cfg.contents || {};
  const accounts = cfg.accounts || {};
  const users = Array.isArray(accounts.users) ? accounts.users : [];

  let entrypoint = null;
  if (cfg.entrypoint) {
    if (typeof cfg.entrypoint === 'string') entrypoint = cfg.entrypoint;
    else if (cfg.entrypoint.command) entrypoint = cfg.entrypoint.command;
    else if (cfg.entrypoint.services) entrypoint = `services: ${Object.keys(cfg.entrypoint.services).join(', ')}`;
    else if (cfg.entrypoint.type) entrypoint = `(${cfg.entrypoint.type})`;
  }

  const uid = accounts['run-as'] ?? (users[0] && users[0].uid);
  const runAs = users.find((u) => String(u.uid) === String(uid)) || users[0];
  const username = runAs && runAs.username;

  return {
    entrypoint,
    cmd: cfg.cmd ?? null,
    env: cfg.environment && typeof cfg.environment === 'object' ? cfg.environment : {},
    user: username ? `${username}${uid != null ? ` (${uid})` : ''}` : (uid != null ? String(uid) : null),
    uid: uid != null && !Number.isNaN(Number(uid)) ? Number(uid) : null,
    workdir: cfg['work-dir'] ?? null,
    archs: Array.isArray(cfg.archs) ? cfg.archs : [],
    labels: cfg.annotations && typeof cfg.annotations === 'object' ? cfg.annotations : {},
    exposedPorts: [],
    volumes: [],
    packagesRequested: Array.isArray(contents.packages) ? contents.packages.map(String) : [],
    source: 'apko',
  };
}

//--- registry: image config, archs, size -------------------------------------

const ACCEPT = [
  'application/vnd.oci.image.index.v1+json',
  'application/vnd.docker.distribution.manifest.list.v2+json',
  'application/vnd.oci.image.manifest.v1+json',
  'application/vnd.docker.distribution.manifest.v2+json',
].join(', ');

const tokens = new Map();
async function registryToken(registry, repo) {
  if (tokens.has(repo)) return tokens.get(repo);
  const res = await fetchWithTimeout(`https://${registry}/token?scope=repository:${repo}:pull&service=${registry}`);
  if (!res.ok) throw new Error(`token ${res.status}`);
  const { token } = await res.json();
  tokens.set(repo, token);
  return token;
}

async function registryGet(registry, repo, path, accept) {
  const token = await registryToken(registry, repo);
  const res = await fetchWithTimeout(`https://${registry}/v2/${repo}/${path}`, {
    headers: { Authorization: `Bearer ${token}`, ...(accept ? { Accept: accept } : {}) },
  });
  if (!res.ok) throw new Error(`${path.split('/')[0]} ${res.status}`);
  return res.json();
}

// Resolve the multi-arch index at `digest`, then read the amd64 manifest (or
// the first one) for size + config. Best-effort: any failure returns null and
// the page falls back to the apko recipe.
async function fetchRegistryInfo(registry, repo, digest) {
  if (SKIP_REGISTRY || !digest) return null;
  const top = await registryGet(registry, repo, `manifests/${digest}`, ACCEPT);
  let manifest = top;
  let archs = [];
  if (Array.isArray(top.manifests)) {
    const images = top.manifests.filter((m) => m.platform && m.platform.os !== 'unknown');
    archs = images.map((m) => m.platform.architecture + (m.platform.variant ? `/${m.platform.variant}` : ''));
    const pick = images.find((m) => m.platform.architecture === 'amd64') || images[0];
    if (!pick) throw new Error('index has no platform manifests');
    manifest = await registryGet(registry, repo, `manifests/${pick.digest}`, ACCEPT);
  }
  const layers = Array.isArray(manifest.layers) ? manifest.layers : [];
  const size = layers.reduce((n, l) => n + (l.size || 0), 0) + ((manifest.config && manifest.config.size) || 0);
  const cfgDoc = await registryGet(registry, repo, `blobs/${manifest.config.digest}`);
  if (!archs.length && cfgDoc.architecture) archs = [cfgDoc.architecture];
  return { size, archs, layers: layers.length, config: cfgDoc.config || {}, created: cfgDoc.created || null };
}

function specsFromConfig(base, info) {
  const c = info.config;
  const env = {};
  for (const kv of c.Env || []) {
    const i = kv.indexOf('=');
    if (i > 0) env[kv.slice(0, i)] = kv.slice(i + 1);
  }
  const user = c.User || null;
  // Keep apko's "name (uid)" form when the config only carries the bare uid.
  const userLabel = base && base.uid != null && user === String(base.uid) ? base.user : user;
  return {
    entrypoint: Array.isArray(c.Entrypoint) ? c.Entrypoint.join(' ') : (base && base.entrypoint) || null,
    cmd: Array.isArray(c.Cmd) ? c.Cmd.join(' ') : null,
    env,
    user: userLabel,
    uid: user && /^\d+/.test(user) ? Number(user.split(':')[0]) : (base ? base.uid : null),
    workdir: c.WorkingDir || null,
    archs: info.archs,
    labels: c.Labels || {},
    exposedPorts: c.ExposedPorts ? Object.keys(c.ExposedPorts) : [],
    volumes: c.Volumes ? Object.keys(c.Volumes) : [],
    packagesRequested: base ? base.packagesRequested : [],
    layers: info.layers,
    created: info.created,
    source: 'registry',
  };
}

//--- grype scan --------------------------------------------------------------

const SEV = ['Critical', 'High', 'Medium', 'Low', 'Negligible', 'Unknown'];

function readScan(scan) {
  if (!scan || !Array.isArray(scan.matches)) return null;
  const counts = { critical: 0, high: 0, medium: 0, low: 0, negligible: 0, unknown: 0 };
  let fixable = 0;
  const list = [];
  for (const m of scan.matches) {
    const v = m.vulnerability || {};
    const a = m.artifact || {};
    const key = String(v.severity || 'Unknown').toLowerCase();
    if (key in counts) counts[key]++; else counts.unknown++;
    const fixed = v.fix && v.fix.state === 'fixed' && Array.isArray(v.fix.versions) ? v.fix.versions : [];
    if (fixed.length > 0) fixable++;
    list.push({
      id: v.id || 'UNKNOWN',
      severity: SEV.find((s) => s.toLowerCase() === key) || 'Unknown',
      package: a.name || '',
      installed: a.version || '',
      fixedIn: fixed[0] || null,
      fixState: (v.fix && v.fix.state) || null,
      url: v.dataSource || null,
    });
  }
  const order = Object.fromEntries(SEV.map((s, i) => [s, i]));
  list.sort((x, y) => (order[x.severity] - order[y.severity]) || x.id.localeCompare(y.id));
  const d = scan.descriptor || {};
  const db = (d.db && (d.db.status || d.db)) || {};
  return {
    counts,
    fixable,
    total: list.length,
    // Same gate the workflows sign on: any finding Low or above blocks cosign.
    lowPlus: counts.critical + counts.high + counts.medium + counts.low,
    scanner: d.version ? `grype ${d.version}` : 'grype',
    dbBuilt: db.built || null,
    list,
  };
}

//--- assemble ----------------------------------------------------------------

async function buildRecord(entry, ctx, built) {
  const { registry, repository } = ctx;
  const major = built ? built.major ?? null : null;
  const repo = `${registry}/${repository}/${entry.name}`;
  const slug = major != null ? `${entry.name}-${major}` : entry.name;
  const displayName = major != null ? `${entry.display_name || entry.name} ${major}` : (entry.display_name || entry.name);
  const record = {
    name: entry.name,
    slug,
    displayName,
    major,
    category: entry.category,
    summary: entry.summary || '',
    description: entry.description || '',
    upstreamUrl: entry.upstream_url || null,
    primaryPackage: entry.primary_package ? entry.primary_package.replaceAll('@@MAJOR@@', String(major ?? '')) : null,
    sourceDir: `images/${entry.dir}`,
    workflow: (built && built.signed_by) || entry.workflow || null,
    repo,
    version: (built && built.version) || null,
    builtWith: (built && built.built_with) || null,
    tags: built && Array.isArray(built.tags) ? built.tags.map(String) : [],
    digest: (built && built.digest) || null,
    builtAt: (built && built.built) || null,
    updatedAgo: agoFrom(built && built.built),
    signed: Boolean(built && built.signed),
    size: null,
    archs: [],
    specs: null,
    vulnerabilities: null,
    dataStatus: { build: Boolean(built), scan: false, apko: false, registry: false },
    degraded: false,
    notes: [],
  };

  // Requested packages + fallback specs from the apko recipe.
  let apkoSpecs = null;
  const apkoPath = join(REPO_DIR, 'images', entry.dir, 'apko', entry.apko || '');
  if (entry.apko && existsSync(apkoPath)) {
    apkoSpecs = tryOr(() => specsFromApko(apkoPath, major), (e) => record.notes.push(`apko parse failed: ${e.message}`));
    if (apkoSpecs) record.dataStatus.apko = true;
  } else {
    record.notes.push('no apko config found');
  }
  record.specs = apkoSpecs;

  if (built) {
    const vulns = tryOr(() => readScan(built.scan), (e) => record.notes.push(`scan: ${e.message}`));
    if (vulns) {
      record.vulnerabilities = vulns;
      record.dataStatus.scan = true;
    } else {
      record.notes.push('no scan in build entry');
    }
    try {
      const info = await fetchRegistryInfo(registry, `${repository}/${entry.name}`, record.digest);
      if (info) {
        record.dataStatus.registry = true;
        record.size = { bytes: info.size, human: humanBytes(info.size) };
        record.archs = info.archs;
        record.specs = specsFromConfig(apkoSpecs, info);
      }
    } catch (e) {
      warn(`registry(${slug}): ${e.message}`);
    }
  } else {
    record.notes.push('not built yet');
  }
  if (!record.archs.length && apkoSpecs) record.archs = apkoSpecs.archs;

  record.degraded = !record.dataStatus.build || !record.dataStatus.scan;
  return record;
}

function readIndex() {
  if (!INDEX_FILE) return [];
  try {
    const raw = readJson(INDEX_FILE);
    if (!Array.isArray(raw)) throw new Error('not an array');
    return raw;
  } catch (e) {
    warn(`index ${INDEX_FILE} unreadable: ${e.message} — rendering without build data`);
    return [];
  }
}

//--- main --------------------------------------------------------------------

async function main() {
  let catalog;
  try {
    catalog = readJson(join(REPO_DIR, 'catalog.json'));
  } catch (e) {
    console.error(`FATAL: cannot read catalog.json: ${e.message}`);
    process.exit(1);
  }
  const entries = Array.isArray(catalog.images) ? catalog.images : [];
  if (entries.length === 0) {
    console.error('FATAL: catalog.json has no images');
    process.exit(1);
  }
  const ctx = { registry: catalog.registry || 'ghcr.io', repository: catalog.repository };
  const index = readIndex();
  console.log(`Building catalog: ${entries.length} catalog entries, ${index.length} build entries${INDEX_FILE ? ` (${INDEX_FILE})` : ' (no index — metadata + specs only)'}`);

  const records = [];
  const matched = new Set();
  for (const entry of entries) {
    const repo = `${ctx.registry}/${ctx.repository}/${entry.name}`;
    const builds = index.filter((b) => b && b.image === repo);
    builds.forEach((b) => matched.add(b));
    // per_major images (postgres) get one page per published major, newest first.
    const targets = entry.per_major
      ? builds.filter((b) => b.major != null).sort((a, b) => b.major - a.major)
      : [builds.find((b) => b.major == null) || builds[0] || null];
    if (entry.per_major && targets.length === 0) targets.push(null);
    for (const built of targets) {
      try {
        records.push(await buildRecord(entry, ctx, built));
      } catch (e) {
        warn(`image "${entry.name}" failed hard: ${e.message}`);
      }
    }
  }
  for (const b of index) {
    if (!matched.has(b)) warn(`index entry ${b && b.image} has no catalog.json entry — not rendered`);
  }

  if (INDEX_FILE && index.length > 0 && !records.some((r) => r.dataStatus.build)) {
    console.error('FATAL: index was provided but matched zero catalog images — refusing to publish an empty catalog');
    process.exit(1);
  }

  const pgMajors = records
    .filter((r) => r.major != null && r.digest && r.version)
    .map((r) => ({ major: r.major, image: `${r.repo}:${r.version}@${r.digest}` }))
    .sort((a, b) => a.major - b.major);

  const degraded = records.filter((r) => r.degraded);
  const out = {
    generatedAt: new Date().toISOString(),
    buildDate: process.env.BUILD_DATE || new Date().toISOString().replace('T', ' ').slice(0, 16) + ' UTC',
    commitSha: process.env.COMMIT_SHA || '',
    runUrl: process.env.RUN_URL || '',
    registry: ctx.registry,
    repository: ctx.repository,
    categories: catalog.categories || [],
    hasScanData: records.some((r) => r.dataStatus.scan),
    lastBuild: records.map((r) => r.builtAt).filter(Boolean).sort().pop() || null,
    clusterImageCatalog: pgMajors,
    counts: { images: records.length, full: records.length - degraded.length, degraded: degraded.length },
    images: records,
  };

  mkdirSync(dirname(OUT_FILE), { recursive: true });
  writeFileSync(OUT_FILE, JSON.stringify(out, null, 2) + '\n');

  console.log(`\nWrote ${OUT_FILE}`);
  console.log(`  ${records.length} pages · ${out.counts.full} full · ${degraded.length} degraded`);
  if (degraded.length) {
    console.log('  degraded: ' + degraded.map((r) => `${r.slug} (${r.notes.join('; ') || 'partial'})`).join(', '));
  }

  if (process.env.GITHUB_STEP_SUMMARY) {
    const lines = [
      '### Catalog data build',
      '',
      `- Pages: **${records.length}**`,
      `- Full data: **${out.counts.full}**`,
      `- Degraded: **${degraded.length}**`,
    ];
    if (degraded.length) {
      lines.push('', '| Image | Missing |', '|---|---|');
      for (const r of degraded) lines.push(`| ${r.slug} | ${r.notes.join('; ') || 'partial'} |`);
    }
    if (warnings.length) {
      lines.push('', `<details><summary>${warnings.length} warnings</summary>`, '', ...warnings.map((w) => `- ${w}`), '', '</details>');
    }
    try { writeFileSync(process.env.GITHUB_STEP_SUMMARY, lines.join('\n') + '\n', { flag: 'a' }); } catch { /* noop */ }
  }
}

main().catch((e) => {
  console.error(`FATAL: ${e.stack || e.message}`);
  process.exit(1);
});
