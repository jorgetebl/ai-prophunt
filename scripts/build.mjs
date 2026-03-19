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
const BANNER = 'var __bundled_src_dir = require("path").join(__dirname, "src");';

function buildBundle(entry, outfile, step, total) {
  console.log(`Step ${step}/${total} — Bundling ${entry}...`);
  execSync(
    `npx esbuild ${entry} --bundle --platform=node --target=node20 --format=cjs --outfile=${outfile} --define:"import.meta.dirname"=__bundled_src_dir --define:"import.meta.filename"=__filename --banner:js='${BANNER}' --log-level=warning`,
    { cwd: ROOT, stdio: 'inherit' }
  );
}

buildBundle('src/server.js', 'dist/server.bundle.cjs', 1, 4);
// index.js imports auth.js/search.js which have top-level await in CLI blocks.
// Use ESM format to support top-level await, then wrap in a CJS launcher.
console.log('Step 2/4 — Bundling API search...');
execSync(
  `npx esbuild src/index.js --bundle --platform=node --target=node20 --format=esm --outfile=dist/search.bundle.mjs --define:"import.meta.dirname"=__bundled_src_dir --define:"import.meta.filename"=__filename --banner:js='${BANNER}' --log-level=warning`,
  { cwd: ROOT, stdio: 'inherit' }
);

// ── Step 2: Create launcher script ───────────────────────────────────────────
// The bundle runs with the system Node (installed by install.sh).
// A tiny launcher script makes it feel like a native binary.
console.log('Step 3/4 — Creating launcher script...');
const launcher = `#!/bin/bash
exec node "$(dirname "$0")/server.bundle.cjs" "$@"
`;
import { writeFileSync, chmodSync } from 'node:fs';
writeFileSync(join(DIST, 'prophunt-server'), launcher);
chmodSync(join(DIST, 'prophunt-server'), 0o755);

// ── Step 3: Package Chrome extension ─────────────────────────────────────────
console.log('Step 4/4 — Packaging chrome extension...');
execSync(
  `cd chrome-extension && zip -r ../dist/chrome-extension.zip . -x "*.DS_Store"`,
  { cwd: ROOT, stdio: 'inherit' }
);

console.log('\nBuild complete:');
execSync('ls -lh dist/', { cwd: ROOT, stdio: 'inherit' });
