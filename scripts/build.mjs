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
console.log('Step 1/3 — Bundling ESM → CJS with esbuild...');
execSync(
  `npx esbuild src/server.js \
    --bundle \
    --platform=node \
    --target=node20 \
    --format=cjs \
    --outfile=dist/server.bundle.cjs \
    --define:"import.meta.dirname"=__dirname \
    --define:"import.meta.filename"=__filename \
    --log-level=warning`,
  { cwd: ROOT, stdio: 'inherit' }
);

// ── Step 2: Compile to native binary (CI only) ────────────────────────────────
// pkg is blocked by macOS SIP/Gatekeeper locally. Run in GitHub Actions.
if (IS_CI) {
  console.log('Step 2/3 — Compiling to native binaries with pkg...');
  execSync(
    `npx pkg dist/server.bundle.cjs \
      --targets node20-macos-arm64,node20-macos-x64 \
      --output dist/prophunt \
      --compress GZip`,
    { cwd: ROOT, stdio: 'inherit' }
  );
} else {
  console.log('Step 2/3 — Skipping pkg binary (only runs in CI).');
  console.log('           Push to main to trigger GitHub Actions build.');
}

// ── Step 3: Package Chrome extension ─────────────────────────────────────────
console.log('Step 3/3 — Packaging chrome extension...');
execSync(
  `cd chrome-extension && zip -r ../dist/chrome-extension.zip . -x "*.DS_Store"`,
  { cwd: ROOT, stdio: 'inherit' }
);

console.log('\nBuild complete:');
execSync('ls -lh dist/', { cwd: ROOT, stdio: 'inherit' });
