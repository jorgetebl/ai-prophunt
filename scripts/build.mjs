#!/usr/bin/env node
/**
 * Build script: ESM → CJS bundle → native binary
 *
 * Output:
 *   dist/prophunt-macos-arm64   (Apple Silicon)
 *   dist/prophunt-macos-x64     (Intel Mac)
 *   dist/chrome-extension.zip   (extension for Chrome)
 */

import { execSync } from 'node:child_process';
import { mkdirSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const ROOT = join(dirname(fileURLToPath(import.meta.url)), '..');
const DIST = join(ROOT, 'dist');
const IS_CI = Boolean(process.env.CI);

mkdirSync(DIST, { recursive: true });

// ── Step 1: Bundle ESM → CJS ──────────────────────────────────────────────────
// import.meta.dirname / import.meta.filename don't exist in CJS output,
// so we polyfill them via --define. esbuild replaces the references at build time.
// In dev, source files are in src/, so import.meta.dirname = src/ and
// '../config.json' resolves to project root. In the CJS bundle, __dirname
// IS the project root, so we need '../' to still resolve to project root.
// Solution: define import.meta.dirname as __dirname+"/src" via banner.
const CJS_BANNER = 'var __bundled_src_dir = require("path").join(__dirname, "src");';
const ESM_BANNER = 'import { join as __join } from "path"; import { fileURLToPath as __toPath } from "url"; import { dirname as __dirn } from "path"; var __bundled_src_dir = __join(__dirn(__toPath(import.meta.url)), "src");';

console.log('Step 1/4 — Bundling server (CJS)...');
execSync(
  `npx esbuild src/server.js --bundle --platform=node --target=node20 --format=cjs --outfile=dist/server.bundle.cjs --define:"import.meta.dirname"=__bundled_src_dir --define:"import.meta.filename"=__filename --banner:js='${CJS_BANNER}' --log-level=warning`,
  { cwd: ROOT, stdio: 'inherit' }
);

console.log('Step 2/4 — Bundling API search (CJS)...');
execSync(
  `npx esbuild src/index.js --bundle --platform=node --target=node20 --format=cjs --outfile=dist/search.bundle.cjs --define:"import.meta.dirname"=__bundled_src_dir --define:"import.meta.filename"=__filename --banner:js='${CJS_BANNER}' --log-level=warning`,
  { cwd: ROOT, stdio: 'inherit' }
);

// ── Step 2: Create launcher script ───────────────────────────────────────────
// The bundle runs with the system Node (installed by install.sh).
// A tiny launcher script makes it feel like a native binary.
console.log('Step 3/4 — Creating launcher script...');
const launcher = `#!/bin/bash
exec node "$(dirname "$0")/server.bundle.cjs" "$@"
`;
import { writeFileSync, chmodSync, existsSync, copyFileSync } from 'node:fs';
writeFileSync(join(DIST, 'prophunt-server'), launcher);
chmodSync(join(DIST, 'prophunt-server'), 0o755);

// ── Step 3: Package Chrome extension ─────────────────────────────────────────
console.log('Step 4/4 — Packaging chrome extension...');
execSync(
  `cd chrome-extension && zip -r ../dist/chrome-extension.zip . -x "*.DS_Store"`,
  { cwd: ROOT, stdio: 'inherit' }
);

// ── Step 5: Copy release assets to landing/ for Netlify hosting ────────────
const LANDING_RELEASES = join(ROOT, 'landing', 'releases');
mkdirSync(LANDING_RELEASES, { recursive: true });
for (const f of ['server.bundle.cjs', 'search.bundle.cjs', 'chrome-extension.zip']) {
  const src = join(DIST, f);
  if (existsSync(src)) {
    copyFileSync(src, join(LANDING_RELEASES, f));
  }
}
// Also copy supporting files
for (const f of ['run.sh', 'install.sh', 'config.example.json']) {
  const src = join(ROOT, f);
  if (existsSync(src)) {
    copyFileSync(src, join(LANDING_RELEASES, f));
  }
}
const whatsappTpl = join(ROOT, 'templates', 'whatsapp.txt');
if (existsSync(whatsappTpl)) {
  copyFileSync(whatsappTpl, join(LANDING_RELEASES, 'whatsapp.txt'));
}
console.log('Step 5/5 — Release assets copied to landing/releases/');

console.log('\nBuild complete:');
execSync('ls -lh dist/', { cwd: ROOT, stdio: 'inherit' });
