import 'dotenv/config';
import { createServer } from 'node:http';
import { createConnection } from 'node:net';
import { readFileSync, existsSync } from 'node:fs';
import { join, extname } from 'node:path';
import { execSync, spawn } from 'node:child_process';
import { log } from './logger.js';
import { normalizePhone, isValidMobile } from './phone.js';
import { loadContacted, getTodayContactCount } from './filter.js';
import { createQueue } from './queue.js';
import { isConfigured, getUserId, getContacts, getLogs as sbGetLogs, getConfig as sbGetConfig, init as initSupabase } from './supabase.js';

const CONFIG_PATH = join(import.meta.dirname, '..', 'config.json');
const config = JSON.parse(readFileSync(CONFIG_PATH, 'utf-8'));

const dryRun = process.argv.includes('--dry-run');
const dashboardMode = process.argv.includes('--dashboard');
const PORT = config.server?.port || Number(process.env.BRIDGE_PORT) || 3456;
const PROJECT_ROOT = join(import.meta.dirname, '..');
const PUBLIC_DIR = join(PROJECT_ROOT, 'public');
const prefixes = config.filters?.valid_phone_prefixes || ['6', '7'];
const maxPerDay = config.filters?.max_contacts_per_day ?? 15;

// --- Queue ---
const queue = createQueue(config, { dryRun });

// --- Helpers ---

function corsHeaders() {
  return {
    'Access-Control-Allow-Origin': '*',
    'Access-Control-Allow-Methods': 'GET, POST, OPTIONS',
    'Access-Control-Allow-Headers': 'Content-Type',
  };
}

function json(res, statusCode, data) {
  const body = JSON.stringify(data);
  res.writeHead(statusCode, { ...corsHeaders(), 'Content-Type': 'application/json' });
  res.end(body);
}

function readBody(req) {
  return new Promise((resolve, reject) => {
    const chunks = [];
    req.on('data', (chunk) => chunks.push(chunk));
    req.on('end', () => {
      try {
        resolve(JSON.parse(Buffer.concat(chunks).toString()));
      } catch {
        reject(new Error('Invalid JSON'));
      }
    });
    req.on('error', reject);
  });
}

async function getTodayCount() {
  return await getTodayContactCount();
}

function isInQueue(phone, url) {
  const state = queue.getState();
  return state.items.some(i => i.phone === phone || (url && i.url === url));
}

function isDuplicateInContacted(phone, url) {
  const contacted = loadContacted();
  const phones = new Set(contacted.contacts.map(c => c.phone));
  const urls = new Set(contacted.contacts.map(c => c.url));
  if (phones.has(`34${phone}`) || phones.has(phone)) return true;
  if (url && urls.has(url)) return true;
  return false;
}

// --- Route handlers ---

async function handleContact(req, res) {
  let body;
  try {
    body = await readBody(req);
  } catch {
    return json(res, 400, { error: 'Invalid JSON body' });
  }

  if (!body.phone) {
    return json(res, 400, { error: 'Missing required field: phone' });
  }
  if (!body.url) {
    return json(res, 400, { error: 'Missing required field: url' });
  }
  if (!body.portal) {
    return json(res, 400, { error: 'Missing required field: portal' });
  }

  const phone = normalizePhone(body.phone);
  if (!phone) {
    return json(res, 422, { error: 'Could not normalize phone number' });
  }
  if (!isValidMobile(phone, prefixes)) {
    return json(res, 422, { error: `Phone must start with ${prefixes.join(' or ')} (mobile)` });
  }

  if (isDuplicateInContacted(phone, body.url)) {
    return json(res, 409, { error: 'Contact already exists (phone or URL)' });
  }

  if (isInQueue(phone, body.url)) {
    return json(res, 409, { error: 'Contact already in queue' });
  }

  const todayCount = (await getTodayCount()) + queue.getState().queueLength;
  if (todayCount >= maxPerDay) {
    return json(res, 429, { error: `Daily limit reached (${maxPerDay})` });
  }

  const contact = {
    phone,
    url: body.url,
    portal: body.portal,
    zone: body.zone || '',
    propertyCode: body.propertyCode || '',
    price: body.price || null,
    name: body.name || '',
  };

  const { position } = queue.enqueue(contact);

  const minDelay = (config.filters?.min_delay_between_messages_seconds ?? 120) * 1000;
  const estimatedMs = position * minDelay;
  const estimatedSendTime = new Date(Date.now() + estimatedMs).toISOString();

  json(res, 202, { status: 'queued', position, estimatedSendTime });
}

async function handleStatus(_req, res) {
  const state = queue.getState();
  const todayCount = await getTodayCount();
  json(res, 200, {
    ok: true,
    dryRun,
    queue: {
      length: state.queueLength,
      processing: state.processing,
      paused: state.paused,
    },
    schedule: {
      withinWorkingHours: state.withinSchedule,
    },
    stats: {
      todayCount,
      maxPerDay: state.maxPerDay,
      lastSendTime: state.lastSendTime,
    },
  });
}

function handleQueue(_req, res) {
  const state = queue.getState();
  json(res, 200, { items: state.items, length: state.queueLength });
}

function handleHealth(_req, res) {
  json(res, 200, { ok: true, dryRun, port: PORT, uptime: process.uptime() });
}

function handlePause(_req, res) {
  queue.pause();
  json(res, 200, { status: 'paused' });
}

function handleResume(_req, res) {
  queue.resume();
  json(res, 200, { status: 'resumed' });
}

async function handleShutdown(_req, res) {
  json(res, 200, { status: 'shutting_down' });
  await queue.shutdown();
  log('Server: shutdown complete');
  process.exit(0);
}

// --- Dashboard API handlers ---

const MIME_TYPES = {
  '.html': 'text/html',
  '.css': 'text/css',
  '.js': 'text/javascript',
  '.json': 'application/json',
  '.png': 'image/png',
  '.svg': 'image/svg+xml',
  '.ico': 'image/x-icon',
};

function serveStatic(filePath, res) {
  const safePath = join(PUBLIC_DIR, filePath).replace(/\.\./g, '');
  if (!safePath.startsWith(PUBLIC_DIR) || !existsSync(safePath)) {
    json(res, 404, { error: 'Not found' });
    return;
  }
  try {
    const content = readFileSync(safePath);
    const ext = extname(safePath);
    const mime = MIME_TYPES[ext] || 'application/octet-stream';
    res.writeHead(200, { ...corsHeaders(), 'Content-Type': mime });
    res.end(content);
  } catch {
    json(res, 500, { error: 'Error reading file' });
  }
}

async function handleApiContacts(req, res) {
  const url = new URL(req.url, `http://${req.headers.host}`);
  const dateParam = url.searchParams.get('date');
  const sinceParam = url.searchParams.get('since');

  if (isConfigured()) {
    const userId = await getUserId();
    const contacts = await getContacts(userId, { date: dateParam, since: sinceParam });
    return json(res, 200, { contacts });
  }

  // JSON fallback
  const contacted = loadContacted();
  let contacts = contacted.contacts || [];

  if (dateParam) {
    contacts = contacts.filter(c => c.date_contacted && c.date_contacted.startsWith(dateParam));
  } else if (sinceParam) {
    contacts = contacts.filter(c => c.date_contacted && c.date_contacted >= sinceParam);
  }

  json(res, 200, { contacts });
}

async function handleApiLogs(req, res) {
  const url = new URL(req.url, `http://${req.headers.host}`);
  const date = url.searchParams.get('date') || new Date().toLocaleDateString('sv-SE', { timeZone: 'Europe/Madrid' });

  if (isConfigured()) {
    const userId = await getUserId();
    const logs = await sbGetLogs(userId, date);
    const content = logs.map(l => l.message).join('\n');
    return json(res, 200, { date, content });
  }

  // File fallback
  const logPath = join(PROJECT_ROOT, 'data', 'logs', `${date}.log`);
  if (!existsSync(logPath)) {
    return json(res, 200, { date, content: '' });
  }
  try {
    const content = readFileSync(logPath, 'utf-8');
    json(res, 200, { date, content });
  } catch {
    json(res, 200, { date, content: '' });
  }
}

async function handleApiConfig(_req, res) {
  if (isConfigured()) {
    const userId = await getUserId();
    const sbConfig = await sbGetConfig(userId);
    if (sbConfig) {
      return json(res, 200, {
        agent: { name: config.agent?.name, company: config.agent?.company, role: config.agent?.role },
        filters: {
          max_contacts_per_day: sbConfig.max_contacts_per_day,
          min_delay_between_messages_seconds: sbConfig.min_delay_minutes * 60,
        },
        schedule: sbConfig.schedule,
        server: config.server,
      });
    }
  }

  // File fallback
  const safe = {
    agent: { name: config.agent?.name, company: config.agent?.company, role: config.agent?.role },
    filters: config.filters,
    schedule: config.schedule,
    server: config.server,
  };
  json(res, 200, safe);
}

function handleApiRun(_req, res) {
  const scriptPath = join(PROJECT_ROOT, 'run.sh');
  if (!existsSync(scriptPath)) {
    return json(res, 500, { error: 'run.sh not found' });
  }
  try {
    const child = spawn(scriptPath, ['betterplace'], {
      cwd: PROJECT_ROOT,
      detached: true,
      stdio: 'ignore',
    });
    child.unref();
    json(res, 200, { status: 'launched', pid: child.pid });
  } catch (err) {
    json(res, 500, { error: err.message });
  }
}

function handleApiHealthcheck(_req, res) {
  const scriptPath = join(PROJECT_ROOT, 'scripts', 'healthcheck.sh');
  if (!existsSync(scriptPath)) {
    return json(res, 200, { checks: [{ name: 'healthcheck.sh', ok: false }] });
  }
  try {
    const output = execSync(`bash "${scriptPath}"`, {
      cwd: PROJECT_ROOT,
      timeout: 15000,
      encoding: 'utf-8',
    });
    const checks = [];
    for (const line of output.split('\n')) {
      const okMatch = line.match(/^\s*OK\s+(.+)/);
      const failMatch = line.match(/^\s*FAIL\s+(.+)/);
      if (okMatch) checks.push({ name: okMatch[1].trim(), ok: true });
      if (failMatch) checks.push({ name: failMatch[1].trim(), ok: false });
    }
    json(res, 200, { checks });
  } catch (err) {
    // healthcheck exits non-zero on failures — still parse output
    const output = err.stdout || '';
    const checks = [];
    for (const line of output.split('\n')) {
      const okMatch = line.match(/^\s*OK\s+(.+)/);
      const failMatch = line.match(/^\s*FAIL\s+(.+)/);
      if (okMatch) checks.push({ name: okMatch[1].trim(), ok: true });
      if (failMatch) checks.push({ name: failMatch[1].trim(), ok: false });
    }
    json(res, 200, { checks });
  }
}

// --- Router ---

const routes = {
  'POST /contact': handleContact,
  'GET /status': handleStatus,
  'GET /queue': handleQueue,
  'GET /health': handleHealth,
  'POST /pause': handlePause,
  'POST /resume': handleResume,
  'POST /shutdown': handleShutdown,
  // Dashboard API
  'GET /api/contacts': handleApiContacts,
  'GET /api/logs': handleApiLogs,
  'GET /api/config': handleApiConfig,
  'POST /api/run': handleApiRun,
  'GET /api/healthcheck': handleApiHealthcheck,
};

const server = createServer((req, res) => {
  // CORS preflight
  if (req.method === 'OPTIONS') {
    res.writeHead(204, corsHeaders());
    return res.end();
  }

  // Parse URL path without query string for route matching
  const urlPath = req.url.split('?')[0];
  const key = `${req.method} ${urlPath}`;

  // Check exact routes first (original + new API)
  const handler = routes[key];
  if (handler) {
    try {
      const result = handler(req, res);
      if (result && typeof result.catch === 'function') {
        result.catch((err) => {
          log(`Server: unhandled error — ${err.message}`);
          json(res, 500, { error: 'Internal server error' });
        });
      }
    } catch (err) {
      log(`Server: unhandled error — ${err.message}`);
      json(res, 500, { error: 'Internal server error' });
    }
    return;
  }

  // Serve static files from public/ (dashboard)
  if (req.method === 'GET') {
    const filePath = urlPath === '/' ? 'index.html' : urlPath.replace(/^\//, '');
    serveStatic(filePath, res);
    return;
  }

  json(res, 404, { error: 'Not found' });
});

// --- Port detection & startup ---

function isPortInUse(port) {
  return new Promise((resolve) => {
    const conn = createConnection({ port, host: '127.0.0.1' });
    conn.on('connect', () => {
      conn.end();
      resolve(true);
    });
    conn.on('error', () => {
      resolve(false);
    });
  });
}

async function start() {
  const inUse = await isPortInUse(PORT);
  if (inUse) {
    log(`Server: port ${PORT} already in use — another instance running. Exiting.`);
    process.exit(0);
  }

  // Resolve Supabase user before starting
  if (isConfigured()) {
    const ready = await initSupabase();
    if (ready) {
      const uid = await getUserId();
      log(`Server: Supabase connected (user: ${uid})`);
    } else {
      log('Server: Supabase configured but could not resolve user — using local JSON files');
    }
  } else {
    log('Server: Supabase not configured, using local JSON files');
  }

  server.listen(PORT, '127.0.0.1', () => {
    log(`Server: listening on http://127.0.0.1:${PORT} (dry-run: ${dryRun})`);
  });
}

// --- Graceful shutdown on signals ---

function gracefulShutdown(signal) {
  log(`Server: received ${signal}, shutting down...`);
  queue.shutdown().then(() => {
    server.close(() => {
      log('Server: closed');
      process.exit(0);
    });
    // Force exit after 5s if server.close hangs
    setTimeout(() => process.exit(0), 5000);
  });
}

process.on('SIGINT', () => gracefulShutdown('SIGINT'));
process.on('SIGTERM', () => gracefulShutdown('SIGTERM'));

start();
