import 'dotenv/config';
import { createServer } from 'node:http';
import { createConnection } from 'node:net';
import { readFileSync, existsSync, appendFileSync, writeFileSync } from 'node:fs';
import { join, extname } from 'node:path';
import { execSync, execFile, spawn } from 'node:child_process';
import { log } from './logger.js';
import { normalizePhone, isValidMobile } from './phone.js';
import { loadContacted, getTodayContactCount } from './filter.js';
import { createQueue } from './queue.js';
import { isConfigured, getUserId, getContacts, addContact, getLogs as sbGetLogs, getConfig as sbGetConfig, init as initSupabase, reportVersion } from './supabase.js';
import { parseEmail, extractPhone, extractDetails, buildMessage as claudeBuildMessage, setAccessToken } from './claude.js';

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

async function saveSkippedContact(prop, status, phone) {
  const contactData = {
    phone: phone ? `34${normalizePhone(phone) || phone}` : '',
    name: prop.name || '',
    url: prop.url,
    propertyCode: prop.propertyCode || '',
    portal: prop.portal || 'idealista',
    zone: prop.zone || '',
    price: prop.price || null,
    date_contacted: new Date().toISOString(),
    status,
    message_preview: '',
  };

  try {
    if (isConfigured()) {
      await addContact(await getUserId(), contactData);
    }
  } catch (err) {
    log(`saveSkippedContact supabase error: ${err.message}`);
  }

  // Always write to local JSON
  const contacted = loadContacted();
  contacted.contacts.push(contactData);
  writeFileSync(join(import.meta.dirname, '..', 'data', 'contacted.json'), JSON.stringify(contacted, null, 2) + '\n');
}

function isDuplicateInContacted(phone, url) {
  const contacted = loadContacted();
  const phones = new Set(contacted.contacts.map(c => c.phone));
  const urls = new Set(contacted.contacts.map(c => c.url));
  if (phones.has(`34${phone}`) || phones.has(phone)) return true;
  if (url && urls.has(url)) return true;
  return false;
}

// --- BetterPlace Pipeline State Machine ---

/**
 * States:
 * IDLE → GMAIL_NAVIGATE → GMAIL_NAVIGATE_WAITING → GMAIL_LINKS_PENDING
 *      → [for each Gmail email]:
 *          GMAIL_EMAIL_NAVIGATE → GMAIL_EMAIL_NAVIGATE_WAITING → GMAIL_EMAIL_DOM_PENDING
 *          → EMAIL_PARSING (accumulate properties)
 *      → [for each property]:
 *          PROPERTY_NAVIGATE → DOM_PENDING → DOM_RECEIVED
 *          → (if click needed) CLICKING → DOM_PENDING_2
 *          → PHONE_FOUND | PHONE_FAILED
 *      → DONE
 */

let pipeline = {
  state: 'IDLE',
  taskId: null,
  emailUrls: [],       // Gmail thread URLs to open (one per BetterPlace email)
  emailIdx: 0,         // current email index
  properties: [],      // parsed from all emails combined
  currentIdx: 0,
  currentProperty: null,
  clickAttempts: 0,
  results: [],
};

function pipelineLog(msg) {
  const ts = new Date().toLocaleTimeString('es-ES', { timeZone: 'Europe/Madrid' });
  log(`Pipeline [${pipeline.state}]: ${msg}`);
  const dateStr = new Date().toLocaleDateString('sv-SE', { timeZone: 'Europe/Madrid' });
  const logPath = join(PROJECT_ROOT, 'data', 'logs', `${dateStr}.log`);
  try {
    appendFileSync(logPath, `${ts} - ${msg}\n`);
  } catch { /* ignore */ }
}

function nextTaskId() {
  return `task_${Date.now()}_${Math.random().toString(36).slice(2, 7)}`;
}

function nextProperty() {
  while (pipeline.currentIdx < pipeline.properties.length) {
    const prop = pipeline.properties[pipeline.currentIdx];
    pipeline.currentIdx++;
    // Skip duplicates
    const contacted = loadContacted();
    const urls = new Set(contacted.contacts.map(c => c.url));
    if (urls.has(prop.url)) {
      pipelineLog(`SKIP duplicate URL: ${prop.url}`);
      pipeline.results.push({ ...prop, status: 'skipped_duplicate' });
      continue;
    }
    return prop;
  }
  return null;
}

function startNextProperty() {
  const prop = nextProperty();
  if (!prop) {
    pipeline.state = 'DONE';
    pipelineLog(`Done. ${pipeline.results.length} properties processed.`);
    return;
  }
  pipeline.currentProperty = prop;
  pipeline.clickAttempts = 0;
  pipeline.taskId = nextTaskId();
  pipeline.state = 'PROPERTY_NAVIGATE';
  pipelineLog(`Navigating to: ${prop.url}`);
}

async function processPhoneResult(domText) {
  const prop = pipeline.currentProperty;
  const afterClick = pipeline.clickAttempts > 0;
  const result = await extractPhone(domText, prop.portal, { afterClick });

  if (result.found && result.phone) {
    const realPhone = normalizePhone(result.phone);
    // If phone_override is set (test mode), use it instead of the real phone
    const phone = pipeline._phoneOverride ? normalizePhone(pipeline._phoneOverride) : realPhone;
    if (pipeline._phoneOverride) {
      pipelineLog(`Phone override active: real=${realPhone}, sending to=${phone}`);
    }
    if (!realPhone || !isValidMobile(realPhone, prefixes)) {
      pipelineLog(`Phone invalid or landline: ${result.phone} — skip`);
      pipeline.results.push({ ...prop, status: 'skipped_landline' });
      await saveSkippedContact(prop, 'skipped_landline', result.phone);
      startNextProperty();
      return;
    }
    if (!pipeline._phoneOverride && isDuplicateInContacted(phone, prop.url)) {
      pipelineLog(`Phone duplicate: ${phone} — skip`);
      pipeline.results.push({ ...prop, status: 'skipped_duplicate' });
      startNextProperty();
      return;
    }
    pipelineLog(`Phone found: ${realPhone} — queuing WhatsApp to ${phone}`);
    // Fetch user config (template, vars, rate limit)
    let userTemplate, userVars, maxPerDay = 15;
    try {
      const userId = await getUserId();
      if (userId) {
        const cfg = await sbGetConfig(userId);
        if (cfg) {
          userTemplate = cfg.message_template || undefined;
          userVars = cfg.message_vars || undefined;
          maxPerDay = cfg.max_contacts_per_day || 15;
          if (cfg.agent_name) prop._agentName = cfg.agent_name;
          if (cfg.agent_company) prop._agentCompany = cfg.agent_company;
          if (cfg.agent_role) prop._agentRole = cfg.agent_role;
        }
        // Rate limit: check today's contact count
        const today = new Date().toLocaleDateString('sv-SE', { timeZone: 'Europe/Madrid' });
        const todayContacts = await getContacts(userId, { date: today });
        const sentToday = todayContacts.filter(c => ['sent', 'test', 'dry_run', 'queued'].includes(c.status)).length;
        if (sentToday >= maxPerDay) {
          pipelineLog(`Rate limit reached: ${sentToday}/${maxPerDay} contacts today — stopping pipeline`);
          pipeline.results.push({ ...prop, phone, status: 'skipped_rate_limit' });
          pipeline.state = 'DONE';
          pipelineLog(`Done (rate limit). ${pipeline.results.length} properties processed.`);
          return;
        }
      }
    } catch { /* use defaults */ }
    const contact = {
      phone,
      url: prop.url,
      portal: prop.portal,
      zone: prop.zone,
      price: prop.price,
      priceText: prop.priceText,
      name: prop.name || '',
      propertyType: prop.propertyType,
      operation: prop.operation,
      sqm: prop.sqm,
      rooms: prop.rooms,
      floor: prop.floor,
      features: prop.features,
      detail: prop.detail,
      agentName: prop._agentName,
      agentCompany: prop._agentCompany,
      agentRole: prop._agentRole,
      template: userTemplate,
      vars: userVars,
    };
    // Build message via Claude
    let message;
    try {
      message = await claudeBuildMessage(contact);
    } catch (err) {
      log(`Claude buildMessage error: ${err.message}`);
      const { buildMessage: staticBuildMessage } = await import('./message.js');
      message = staticBuildMessage(contact);
    }
    contact.message = message;
    queue.enqueue(contact);
    pipeline.results.push({ ...prop, phone, status: 'queued' });
    startNextProperty();
  } else if (result.action === 'click' && pipeline.clickAttempts < 3) {
    pipeline.clickAttempts++;
    pipeline.taskId = nextTaskId();
    pipeline.state = 'CLICKING';
    pipeline._pendingClickHint = result.hint || 'ver teléfono';
    pipelineLog(`Click needed: "${pipeline._pendingClickHint}" (attempt ${pipeline.clickAttempts})`);
  } else {
    pipelineLog(`No phone found for ${prop.url}`);
    pipeline.results.push({ ...prop, status: 'failed_no_phone' });
    await saveSkippedContact(prop, 'failed_no_phone');
    startNextProperty();
  }
}

// --- Browser task handlers ---

function handleBrowserNextTask(_req, res) {
  const { state, taskId } = pipeline;

  if (state === 'IDLE' || state === 'DONE') {
    return json(res, 200, { type: 'idle' });
  }

  if (state === 'GMAIL_NAVIGATE') {
    pipeline.state = 'GMAIL_NAVIGATE_WAITING';
    return json(res, 200, { type: 'navigate', url: 'https://mail.google.com/#search/from:alertas@betterplaceapp.com+newer_than:1d', taskId });
  }

  if (state === 'GMAIL_NAVIGATE_WAITING') {
    return json(res, 200, { type: 'idle' });
  }

  if (state === 'GMAIL_LINKS_PENDING') {
    return json(res, 200, { type: 'extract_links', taskId });
  }

  if (state === 'GMAIL_EMAIL_NAVIGATE') {
    pipeline.state = 'GMAIL_EMAIL_NAVIGATE_WAITING';
    const url = pipeline.emailUrls[pipeline.emailIdx];
    return json(res, 200, { type: 'navigate', url, taskId });
  }

  if (state === 'GMAIL_EMAIL_NAVIGATE_WAITING') {
    return json(res, 200, { type: 'idle' });
  }

  if (state === 'GMAIL_EMAIL_DOM_PENDING') {
    return json(res, 200, { type: 'extract_dom', taskId });
  }

  if (state === 'PROPERTY_NAVIGATE') {
    // Task dispatched — extension picks it up
    pipeline.state = 'PROPERTY_NAVIGATE_WAITING';
    return json(res, 200, { type: 'navigate', url: pipeline.currentProperty.url, taskId });
  }

  if (state === 'DOM_PENDING' || state === 'DOM_PENDING_2') {
    return json(res, 200, { type: 'extract_dom', taskId });
  }

  if (state === 'CLICKING') {
    const hint = pipeline._pendingClickHint || 'ver teléfono';
    pipeline.state = 'CLICKING_WAITING';
    return json(res, 200, { type: 'click', hint, taskId });
  }

  return json(res, 200, { type: 'idle' });
}

async function handleBrowserDom(req, res) {
  let body;
  try { body = await readBody(req); } catch { return json(res, 400, { error: 'Invalid JSON' }); }

  const { state } = pipeline;

  if (state === 'GMAIL_EMAIL_DOM_PENDING') {
    pipeline.state = 'EMAIL_PARSING';
    json(res, 200, { ok: true });
    try {
      const properties = await parseEmail(body.dom || '');
      pipelineLog(`Email ${pipeline.emailIdx + 1}/${pipeline.emailUrls.length}: ${properties.length} particulares found`);
      pipeline.properties.push(...properties);
    } catch (err) {
      pipelineLog(`parseEmail error on email ${pipeline.emailIdx + 1}: ${err.message}`);
    }
    pipeline.emailIdx++;
    if (pipeline.emailIdx < pipeline.emailUrls.length) {
      pipeline.taskId = nextTaskId();
      pipeline.state = 'GMAIL_EMAIL_NAVIGATE';
      pipelineLog(`Opening email ${pipeline.emailIdx + 1}/${pipeline.emailUrls.length}`);
    } else {
      // Deduplicate properties by URL across emails
      const seen = new Set();
      pipeline.properties = pipeline.properties.filter(p => {
        if (seen.has(p.url)) return false;
        seen.add(p.url);
        return true;
      });
      pipelineLog(`All emails parsed. ${pipeline.properties.length} unique properties total`);
      pipeline.currentIdx = 0;
      startNextProperty();
    }
    return;
  }

  if (state === 'DOM_PENDING' || state === 'DOM_PENDING_2') {
    pipeline.state = 'PROCESSING';
    json(res, 200, { ok: true });
    try {
      // On first DOM extraction, also extract property details
      if (state === 'DOM_PENDING' && !pipeline.currentProperty._detailsExtracted) {
        try {
          const details = await extractDetails(body.dom || '', pipeline.currentProperty.portal);
          pipelineLog(`Details extracted: ${details.zone || '?'}, ${details.priceText || '?'}, ${details.propertyType || '?'}`);
          // Merge details into current property
          const prop = pipeline.currentProperty;
          if (details.zone) prop.zone = details.zone;
          if (details.price) prop.price = details.price;
          if (details.priceText) prop.priceText = details.priceText;
          if (details.propertyType) prop.propertyType = details.propertyType;
          if (details.operation) prop.operation = details.operation;
          if (details.sqm) prop.sqm = details.sqm;
          if (details.rooms) prop.rooms = details.rooms;
          if (details.bathrooms) prop.bathrooms = details.bathrooms;
          if (details.floor) prop.floor = details.floor;
          if (details.features) prop.features = details.features;
          if (details.ownerName) prop.name = details.ownerName;
          if (details.description) prop.detail = details.description;
          prop._detailsExtracted = true;
        } catch (err) {
          pipelineLog(`extractDetails error (non-fatal): ${err.message}`);
        }

        // Check DOM for agency indicators before wasting time on phone extraction
        const domLower = (body.dom || '').toLowerCase();
        if (/\bprofesional\b/.test(domLower) && !/\bparticular\b/.test(domLower)) {
          pipelineLog(`Agency detected in DOM ("Profesional") — skip ${pipeline.currentProperty.url}`);
          pipeline.results.push({ ...pipeline.currentProperty, status: 'skipped_agency_dom' });
          await saveSkippedContact(pipeline.currentProperty, 'skipped_agency_dom');
          startNextProperty();
          return;
        }
      }
      await processPhoneResult(body.dom || '');
    } catch (err) {
      pipelineLog(`processPhoneResult error: ${err.message}`);
      pipeline.results.push({ ...pipeline.currentProperty, status: 'failed_error' });
      await saveSkippedContact(pipeline.currentProperty, 'failed_error');
      startNextProperty();
    }
    return;
  }

  json(res, 200, { ok: true });
}

async function handleBrowserActionDone(req, res) {
  let body;
  try { body = await readBody(req); } catch { return json(res, 400, { error: 'Invalid JSON' }); }

  const { state } = pipeline;
  json(res, 200, { ok: true });

  if (state === 'GMAIL_NAVIGATE_WAITING' && body.action === 'navigate') {
    if (body.ok) {
      pipeline.state = 'GMAIL_LINKS_PENDING';
      pipelineLog('Gmail search loaded — extracting email links');
    } else {
      pipelineLog(`Gmail search navigation failed: ${body.error}`);
      pipeline.state = 'DONE';
    }
    return;
  }

  if (state === 'GMAIL_EMAIL_NAVIGATE_WAITING' && body.action === 'navigate') {
    if (body.ok) {
      pipeline.state = 'GMAIL_EMAIL_DOM_PENDING';
      pipelineLog(`Email ${pipeline.emailIdx + 1}/${pipeline.emailUrls.length} loaded — extracting DOM`);
    } else {
      pipelineLog(`Email ${pipeline.emailIdx + 1} navigation failed: ${body.error} — skipping`);
      pipeline.emailIdx++;
      if (pipeline.emailIdx < pipeline.emailUrls.length) {
        pipeline.taskId = nextTaskId();
        pipeline.state = 'GMAIL_EMAIL_NAVIGATE';
      } else {
        pipelineLog(`All emails processed. ${pipeline.properties.length} properties total`);
        pipeline.currentIdx = 0;
        startNextProperty();
      }
    }
    return;
  }

  if (state === 'PROPERTY_NAVIGATE_WAITING' && body.action === 'navigate') {
    if (body.ok) {
      pipeline.state = 'DOM_PENDING';
    } else {
      pipelineLog(`Property navigation failed: ${body.error}`);
      pipeline.results.push({ ...pipeline.currentProperty, status: 'failed_navigate' });
      await saveSkippedContact(pipeline.currentProperty, 'failed_navigate');
      startNextProperty();
    }
    return;
  }

  if (state === 'CLICKING_WAITING' && body.action === 'click') {
    if (body.ok && body.dom) {
      // Extension sent DOM along with click result — process directly
      pipeline.state = 'PROCESSING';
      try {
        await processPhoneResult(body.dom);
      } catch (err) {
        pipelineLog(`processPhoneResult error: ${err.message}`);
        pipeline.results.push({ ...pipeline.currentProperty, status: 'failed_error' });
        await saveSkippedContact(pipeline.currentProperty, 'failed_error');
        startNextProperty();
      }
    } else if (body.ok) {
      pipeline.state = 'DOM_PENDING_2';
    } else {
      pipelineLog('Click failed — no phone');
      pipeline.results.push({ ...pipeline.currentProperty, status: 'failed_no_phone' });
      await saveSkippedContact(pipeline.currentProperty, 'failed_no_phone');
      startNextProperty();
    }
    return;
  }
}

async function handleBrowserLinks(req, res) {
  let body;
  try { body = await readBody(req); } catch { return json(res, 400, { error: 'Invalid JSON' }); }

  json(res, 200, { ok: true });

  if (pipeline.state !== 'GMAIL_LINKS_PENDING') return;

  const links = body.links || [];
  pipelineLog(`Got ${links.length} BetterPlace email(s) from Gmail search`);

  if (links.length === 0) {
    pipelineLog('No BetterPlace emails found today — done');
    pipeline.state = 'DONE';
    return;
  }

  pipeline.emailUrls = links;
  pipeline.emailIdx = 0;
  pipeline.taskId = nextTaskId();
  pipeline.state = 'GMAIL_EMAIL_NAVIGATE';
  pipelineLog(`Opening email 1/${links.length}`);
}

async function handleRunBetterplace(_req, res) {
  if (pipeline.state !== 'IDLE' && pipeline.state !== 'DONE') {
    return json(res, 409, { error: 'Pipeline already running', state: pipeline.state });
  }

  // Mode + rate limit check before starting
  try {
    const userId = await getUserId();
    if (userId) {
      const cfg = await sbGetConfig(userId);

      // Check mode
      const mode = cfg?.mode || 'betterplace';
      if (mode !== 'betterplace' && mode !== 'both') {
        log(`BetterPlace blocked — user mode is '${mode}'`);
        return json(res, 403, { error: `Modo '${mode}' no permite BetterPlace` });
      }

      const maxPerDay = cfg?.max_contacts_per_day || 15;
      const today = new Date().toLocaleDateString('sv-SE', { timeZone: 'Europe/Madrid' });
      const todayContacts = await getContacts(userId, { date: today });
      const sentToday = todayContacts.filter(c => ['sent', 'test', 'dry_run', 'queued'].includes(c.status)).length;
      if (sentToday >= maxPerDay) {
        log(`Rate limit: ${sentToday}/${maxPerDay} — pipeline blocked`);
        return json(res, 429, { error: `Limite diario alcanzado (${sentToday}/${maxPerDay})` });
      }
    }
  } catch { /* proceed anyway */ }

  // Reset pipeline
  pipeline = {
    state: 'IDLE',
    taskId: nextTaskId(),
    emailUrls: [],
    emailIdx: 0,
    properties: [],
    currentIdx: 0,
    currentProperty: null,
    clickAttempts: 0,
    results: [],
    _pendingClickHint: null,
  };

  json(res, 200, { ok: true, message: 'Pipeline started' });

  // Try gogcli first — if available, read Gmail directly without Chrome extension
  try {
    const gogPath = execSync('command -v gog', { encoding: 'utf-8', timeout: 3000 }).trim();
    if (gogPath) {
      pipelineLog('Pipeline started — fetching emails via gogcli');
      setImmediate(() => fetchEmailsWithGog().catch(err => {
        pipelineLog(`gogcli failed (${err.message}) — falling back to Chrome extension`);
        pipeline.state = 'GMAIL_NAVIGATE';
        pipeline.taskId = nextTaskId();
        pipelineLog('Pipeline started — navigating to Gmail via Chrome');
      }));
      return;
    }
  } catch { /* gogcli not installed, fall through */ }

  // Fallback: Chrome extension navigates to Gmail
  pipeline.state = 'GMAIL_NAVIGATE';
  pipeline.taskId = nextTaskId();
  pipelineLog('Pipeline started — navigating to Gmail via Chrome');
}

async function fetchEmailsWithGog() {
  // Search for BetterPlace emails from today
  let searchOutput;
  try {
    searchOutput = execSync(
      `gog gmail search 'from:alertas@betterplaceapp.com newer_than:1d' --json`,
      { encoding: 'utf-8', timeout: 30000 }
    );
  } catch (err) {
    throw new Error(`gog gmail search failed: ${err.message}`);
  }

  let threads;
  try {
    threads = JSON.parse(searchOutput);
  } catch {
    throw new Error(`gog gmail search returned invalid JSON: ${searchOutput.slice(0, 200)}`);
  }

  if (!Array.isArray(threads) || threads.length === 0) {
    pipelineLog('gogcli: no BetterPlace emails found today — done');
    pipeline.state = 'DONE';
    return;
  }

  pipelineLog(`gogcli: found ${threads.length} BetterPlace email(s)`);

  const allProperties = [];
  for (const thread of threads) {
    const id = thread.id || thread.threadId || thread.messageId;
    if (!id) continue;
    try {
      const msgOutput = execSync(
        `gog gmail messages get ${id} --format text --json`,
        { encoding: 'utf-8', timeout: 15000 }
      );
      let body = '';
      try {
        const msg = JSON.parse(msgOutput);
        body = msg.body || msg.snippet || msg.text || msgOutput;
      } catch {
        body = msgOutput;
      }
      const properties = await parseEmail(body);
      pipelineLog(`gogcli email ${id}: ${properties.length} particulares found`);
      allProperties.push(...properties);
    } catch (err) {
      pipelineLog(`gogcli: error reading email ${id}: ${err.message}`);
    }
  }

  // Deduplicate by URL
  const seen = new Set();
  pipeline.properties = allProperties.filter(p => {
    if (seen.has(p.url)) return false;
    seen.add(p.url);
    return true;
  });

  pipelineLog(`gogcli: ${pipeline.properties.length} unique properties to process`);
  pipeline.currentIdx = 0;
  startNextProperty();
}

// --- Direct URL pipeline (skip Gmail, go straight to property) ---

async function handleRunDirect(req, res) {
  let body;
  try { body = await readBody(req); } catch { return json(res, 400, { error: 'Invalid JSON' }); }

  const { url, portal, zone, price, name, phone_override } = body;
  if (!url) return json(res, 400, { error: 'url is required' });

  if (pipeline.state !== 'IDLE' && pipeline.state !== 'DONE') {
    return json(res, 409, { error: 'Pipeline already running', state: pipeline.state });
  }

  const prop = {
    url,
    portal: portal || 'idealista',
    zone: zone || '',
    price: price || null,
    name: name || '',
  };

  pipeline = {
    state: 'PROPERTY_NAVIGATE',
    taskId: nextTaskId(),
    properties: [prop],
    currentIdx: 1,
    currentProperty: prop,
    clickAttempts: 0,
    results: [],
    _pendingClickHint: null,
    _phoneOverride: phone_override || null,
  };

  pipelineLog(`Direct pipeline started — navigating to: ${url}`);
  json(res, 200, { ok: true, message: 'Direct pipeline started', url });
}

// --- Stripe webhook handler ---

async function handleStripeWebhook(req, res) {
  let rawBody;
  try {
    rawBody = await new Promise((resolve, reject) => {
      const chunks = [];
      req.on('data', c => chunks.push(c));
      req.on('end', () => resolve(Buffer.concat(chunks)));
      req.on('error', reject);
    });
  } catch {
    return json(res, 400, { error: 'Could not read body' });
  }

  const sig = req.headers['stripe-signature'];
  const webhookSecret = process.env.STRIPE_WEBHOOK_SECRET;

  if (!webhookSecret) {
    return json(res, 500, { error: 'Stripe webhook secret not configured' });
  }

  let event;
  try {
    const stripe = (await import('stripe')).default;
    const stripeClient = stripe(process.env.STRIPE_SECRET_KEY);
    event = stripeClient.webhooks.constructEvent(rawBody, sig, webhookSecret);
  } catch (err) {
    log(`Stripe webhook signature error: ${err.message}`);
    return json(res, 400, { error: `Webhook Error: ${err.message}` });
  }

  const { isConfigured: sbConfigured } = await import('./supabase.js');

  if (event.type === 'customer.subscription.created' || event.type === 'customer.subscription.updated') {
    const sub = event.data.object;
    const customerId = sub.customer;
    const priceId = sub.items?.data?.[0]?.price?.id;
    const PRICE_TO_PLAN = {
      [process.env.STRIPE_PRICE_PRO]: 'pro',
      [process.env.STRIPE_PRICE_BASICO]: 'basico',
      [process.env.STRIPE_PRICE_AGENTE]: 'agente',
      [process.env.STRIPE_PRICE_OFICINA]: 'oficina',
      [process.env.STRIPE_PRICE_AGENCIA]: 'agencia',
    };
    const plan = PRICE_TO_PLAN[priceId] || 'basico';

    if (sbConfigured()) {
      try {
        const { createClient } = await import('@supabase/supabase-js');
        const adminClient = createClient(
          process.env.SUPABASE_URL,
          process.env.SUPABASE_SERVICE_KEY || process.env.SUPABASE_ANON_KEY
        );
        await adminClient.from('subscriptions').upsert({
          stripe_customer_id: customerId,
          stripe_subscription_id: sub.id,
          plan,
          status: sub.status === 'active' ? 'active' : 'inactive',
          current_period_end: new Date(sub.current_period_end * 1000).toISOString(),
          updated_at: new Date().toISOString(),
        }, { onConflict: 'stripe_subscription_id' });
        log(`Stripe: subscription upserted (${customerId}, ${plan})`);
      } catch (err) {
        log(`Stripe: Supabase upsert error — ${err.message}`);
      }
    }
  }

  if (event.type === 'customer.subscription.deleted') {
    const sub = event.data.object;
    if (sbConfigured()) {
      try {
        const { createClient } = await import('@supabase/supabase-js');
        const adminClient = createClient(
          process.env.SUPABASE_URL,
          process.env.SUPABASE_SERVICE_KEY || process.env.SUPABASE_ANON_KEY
        );
        await adminClient.from('subscriptions')
          .update({ status: 'canceled', updated_at: new Date().toISOString() })
          .eq('stripe_subscription_id', sub.id);
        log(`Stripe: subscription canceled (${sub.id})`);
      } catch (err) {
        log(`Stripe: Supabase cancel error — ${err.message}`);
      }
    }
  }

  json(res, 200, { received: true });
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

function handlePipelineStatus(_req, res) {
  const queueState = queue.getState();
  json(res, 200, {
    state: pipeline.state,
    done: pipeline.state === 'DONE' || pipeline.state === 'IDLE',
    results: pipeline.results.length,
    current: pipeline.currentProperty?.url || null,
    queue_pending: queueState.items.length,
    queue_sent: queueState.sent,
  });
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
  'GET /pipeline/status': handlePipelineStatus,
  'POST /pause': handlePause,
  'POST /resume': handleResume,
  'POST /shutdown': handleShutdown,
  // Dashboard API
  'GET /api/contacts': handleApiContacts,
  'GET /api/logs': handleApiLogs,
  'GET /api/config': handleApiConfig,
  'POST /api/run': handleApiRun,
  'GET /api/healthcheck': handleApiHealthcheck,
  // BetterPlace pipeline (Chrome extension)
  'GET /browser/next-task': handleBrowserNextTask,
  'POST /browser/dom': handleBrowserDom,
  'POST /browser/links': handleBrowserLinks,
  'POST /browser/action-done': handleBrowserActionDone,
  'POST /api/run-betterplace': handleRunBetterplace,
  'POST /api/run-direct': handleRunDirect,
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
      try {
        const pkg = JSON.parse(readFileSync(join(PROJECT_ROOT, 'package.json'), 'utf-8'));
        await reportVersion(uid, pkg.version);
      } catch (_) {}

      // Login to get JWT for Claude proxy
      const email = process.env.PROPHUNT_EMAIL;
      const password = process.env.PROPHUNT_PASSWORD;
      if (email && password) {
        try {
          const { createClient } = await import('@supabase/supabase-js');
          const sb = createClient(process.env.SUPABASE_URL, process.env.SUPABASE_ANON_KEY);
          const { data, error } = await sb.auth.signInWithPassword({ email, password });
          if (error) throw error;
          setAccessToken(data.session.access_token);
          log('Server: Claude proxy authenticated via Supabase JWT');
          // Refresh token before expiry (every 50 min)
          setInterval(async () => {
            const { data: refreshed } = await sb.auth.refreshSession();
            if (refreshed?.session) setAccessToken(refreshed.session.access_token);
          }, 50 * 60 * 1000);
        } catch (err) {
          log(`Server: WARNING — could not get JWT for Claude proxy: ${err.message}`);
        }
      }
    } else {
      log('Server: Supabase configured but could not resolve user — using local JSON files');
    }
  } else {
    log('Server: Supabase not configured, using local JSON files');
  }

  server.listen(PORT, '127.0.0.1', () => {
    log(`Server: listening on http://127.0.0.1:${PORT} (dry-run: ${dryRun})`);
    startScheduler();
    startAutoUpdate();
  });
}

// --- Daily auto-run scheduler ---

let schedulerLastRunDate = null;

function startScheduler() {
  const schedule = config.schedule || {};
  const runTime = schedule.run_time || '09:00';
  const tz = schedule.timezone || 'Europe/Madrid';
  const workingDays = schedule.working_days || [1, 2, 3, 4, 5];

  log(`Scheduler: daily API search at ${runTime} (${tz}), days: ${workingDays.join(',')}`);

  // Check every 30 seconds
  setInterval(async () => {
    const now = new Date();
    const madridNow = new Date(now.toLocaleString('en-US', { timeZone: tz }));
    const hhmm = madridNow.toTimeString().slice(0, 5); // "HH:MM"
    const today = madridNow.toLocaleDateString('sv-SE'); // "YYYY-MM-DD"
    const dayOfWeek = madridNow.getDay();

    if (
      hhmm >= runTime && hhmm < nextMinute(runTime) &&
      workingDays.includes(dayOfWeek) &&
      schedulerLastRunDate !== today &&
      (pipeline.state === 'IDLE' || pipeline.state === 'DONE')
    ) {
      // Check user mode — only run API search if mode is 'api' or 'both'
      try {
        const userId = await getUserId();
        if (userId) {
          const cfg = await sbGetConfig(userId);
          const mode = cfg?.mode || 'betterplace';
          if (mode !== 'api' && mode !== 'both') {
            log(`Scheduler: skipping API search — user mode is '${mode}'`);
            schedulerLastRunDate = today;
            return;
          }
        }
      } catch { /* proceed */ }

      schedulerLastRunDate = today;
      log(`Scheduler: triggering daily API search (${today} ${hhmm})`);
      runDailyApiSearch();
    }
  }, 30000);
}

function nextMinute(hhmm) {
  const [h, m] = hhmm.split(':').map(Number);
  const totalMin = h * 60 + m + 2; // 2-minute window to catch it
  return `${String(Math.floor(totalMin / 60)).padStart(2, '0')}:${String(totalMin % 60).padStart(2, '0')}`;
}

const NOTIFY_PHONE = '34619458478';

function sendNotification(message) {
  return new Promise((resolve) => {
    execFile('wacli', ['send', 'text', '--to', NOTIFY_PHONE, '--message', message], (err) => {
      if (err) log(`Scheduler: notification failed — ${err.message}`);
      resolve();
    });
  });
}

async function runDailyApiSearch() {
  try {
    // Step 1: Run the search (spawns index.js / search.bundle.cjs)
    const searchCmd = existsSync(join(PROJECT_ROOT, 'src', 'index.js'))
      ? 'node src/index.js'
      : 'node search.bundle.cjs';

    log('Scheduler: running API search...');
    await sendNotification(`Buenos días, acabo de arrancar la búsqueda de hoy. Voy a revisar los inmuebles nuevos en Idealista y contactar a los particulares que encuentre. Te aviso cuando termine 👍`);

    try {
      execSync(searchCmd, { cwd: PROJECT_ROOT, timeout: 120000, stdio: 'pipe' });
    } catch (err) {
      log(`Scheduler: search failed — ${err.message}`);
      await sendNotification(`Ha habido un problema con la búsqueda de hoy, no he podido conectar con Idealista. Lo reviso y lo intento mañana.`);
      return;
    }

    // Step 2: Read pending.json
    const pendingPath = join(PROJECT_ROOT, 'data', 'pending.json');
    if (!existsSync(pendingPath)) {
      log('Scheduler: no pending.json generated');
      return;
    }

    const pending = JSON.parse(readFileSync(pendingPath, 'utf-8'));
    const properties = pending.properties || [];
    if (properties.length === 0) {
      log('Scheduler: no properties to process');
      return;
    }

    log(`Scheduler: ${properties.length} properties to process`);

    // Step 3: Process each property via the pipeline
    for (let i = 0; i < properties.length; i++) {
      const prop = properties[i];
      log(`Scheduler: [${i + 1}/${properties.length}] ${prop.zone || prop.address || prop.url}`);

      // Wait for pipeline to be idle
      let waitCount = 0;
      while (pipeline.state !== 'IDLE' && pipeline.state !== 'DONE') {
        await new Promise(r => setTimeout(r, 2000));
        waitCount++;
        if (waitCount > 90) { // 3 min timeout
          log('Scheduler: pipeline stuck, skipping remaining');
          return;
        }
      }

      // Start pipeline for this property
      pipeline = {
        state: 'PROPERTY_NAVIGATE',
        taskId: nextTaskId(),
        properties: [prop],
        currentIdx: 1,
        currentProperty: {
          url: prop.url,
          portal: prop.portal || 'idealista',
          zone: prop.zone || prop.address || '',
          price: prop.price || null,
          name: prop.name || '',
        },
        clickAttempts: 0,
        results: [],
        _pendingClickHint: null,
        _phoneOverride: null,
      };

      pipelineLog(`Navigating to: ${prop.url}`);

      // Wait for this property to finish (max 3 min)
      let done = false;
      for (let j = 0; j < 36; j++) {
        await new Promise(r => setTimeout(r, 5000));
        if (pipeline.state === 'DONE' || pipeline.state === 'IDLE') {
          done = true;
          break;
        }
      }

      if (!done) {
        log(`Scheduler: timeout on ${prop.url}`);
        pipeline.state = 'DONE';
      }

      // Small pause between properties
      await new Promise(r => setTimeout(r, 3000));
    }

    // Step 4: Wait for WhatsApp queue to drain
    const queueState = queue.getState();
    if (queueState.items.length > 0) {
      log(`Scheduler: waiting for WhatsApp queue (${queueState.items.length} pending)...`);
      for (let i = 0; i < 120; i++) {
        await new Promise(r => setTimeout(r, 5000));
        if (queue.getState().items.length === 0) break;
      }
    }

    const sent = queue.getState().sent;
    const total = properties.length;
    const phonesFound = properties.length - (pipeline.results || []).filter(r => r.status === 'failed_no_phone').length;
    log(`Scheduler: daily run complete — ${sent} WhatsApps sent`);

    if (sent > 0) {
      await sendNotification(`Ya he terminado la ronda de hoy. He revisado ${total} inmuebles, he conseguido ${sent} teléfonos de particulares y les he escrito a todos. Mañana vuelvo a buscar, cualquier cosa me dices.`);
    } else {
      await sendNotification(`He terminado de revisar los ${total} inmuebles de hoy pero no he conseguido extraer teléfonos nuevos. A veces Idealista lo pone difícil. Mañana lo vuelvo a intentar.`);
    }
  } catch (err) {
    log(`Scheduler: error — ${err.message}`);
    await sendNotification(`Ha habido un error durante la búsqueda de hoy. Lo reviso y mañana lo intento de nuevo.`).catch(() => {});
  }
}

// --- Auto-update (check for new version every 30 min) ---

let lastUpdateCheck = 0;
const UPDATE_CHECK_INTERVAL = 30 * 60 * 1000; // 30 minutes

function startAutoUpdate() {
  log('Auto-update: checking every 30 min');

  setInterval(async () => {
    // Skip if pipeline is running
    if (pipeline.state !== 'IDLE' && pipeline.state !== 'DONE') return;

    // Skip if checked recently
    if (Date.now() - lastUpdateCheck < UPDATE_CHECK_INTERVAL) return;
    lastUpdateCheck = Date.now();

    try {
      const releasesUrl = 'https://prophunt-app.netlify.app/releases';

      // Download server bundle to temp file and compare size
      const tmpServer = join(PROJECT_ROOT, 'server.bundle.cjs.tmp');
      const currentServer = join(PROJECT_ROOT, 'server.bundle.cjs');

      execSync(`curl -fL "${releasesUrl}/server.bundle.cjs" -o "${tmpServer}" 2>/dev/null`, { timeout: 30000 });

      // Compare with current
      const currentExists = existsSync(currentServer);
      let needsUpdate = !currentExists;

      if (currentExists) {
        const currentSize = readFileSync(currentServer).length;
        const newSize = readFileSync(tmpServer).length;
        if (currentSize !== newSize) {
          needsUpdate = true;
        } else {
          // Same size, compare content hash
          const crypto = await import('node:crypto');
          const currentHash = crypto.createHash('md5').update(readFileSync(currentServer)).digest('hex');
          const newHash = crypto.createHash('md5').update(readFileSync(tmpServer)).digest('hex');
          needsUpdate = currentHash !== newHash;
        }
      }

      if (!needsUpdate) {
        execSync(`rm -f "${tmpServer}"`);
        return;
      }

      log('Auto-update: new version detected, updating...');

      // Update server bundle
      execSync(`mv "${tmpServer}" "${currentServer}"`);
      log('Auto-update: server.bundle.cjs updated');

      // Update search bundle
      const searchBundle = join(PROJECT_ROOT, 'search.bundle.cjs');
      execSync(`curl -fL "${releasesUrl}/search.bundle.cjs" -o "${searchBundle}" 2>/dev/null`, { timeout: 30000 });
      log('Auto-update: search.bundle.cjs updated');

      // Update chrome extension
      const extZip = '/tmp/prophunt-ext-update.zip';
      try {
        execSync(`curl -fL "${releasesUrl}/chrome-extension.zip" -o "${extZip}" 2>/dev/null`, { timeout: 30000 });
        if (existsSync(extZip)) {
          execSync(`unzip -q -o "${extZip}" -d "${join(PROJECT_ROOT, 'chrome-extension')}"`, { timeout: 10000 });
          execSync(`rm -f "${extZip}"`);
          log('Auto-update: chrome-extension updated');
        }
      } catch { /* extension update optional */ }

      // Update run.sh
      try {
        execSync(`curl -fL "${releasesUrl}/run.sh" -o "${join(PROJECT_ROOT, 'run.sh')}" 2>/dev/null && chmod +x "${join(PROJECT_ROOT, 'run.sh')}"`, { timeout: 15000 });
        log('Auto-update: run.sh updated');
      } catch { /* optional */ }

      // Update CLI
      try {
        const installSh = '/tmp/prophunt-install-update.sh';
        execSync(`curl -fL "${releasesUrl}/install.sh" -o "${installSh}" 2>/dev/null`, { timeout: 15000 });
        if (existsSync(installSh)) {
          execSync(`awk '/^cat > \\/tmp\\/prophunt-cli/{found=1;next} /^CLIFEOF$/{found=0;next} found{print}' "${installSh}" > /tmp/prophunt-cli`, { timeout: 5000 });
          execSync('chmod +x /tmp/prophunt-cli', { timeout: 3000 });
          if (existsSync('/tmp/prophunt-cli')) {
            try {
              const cliPath = execSync('command -v prophunt', { encoding: 'utf-8', timeout: 3000 }).trim();
              if (cliPath) {
                execSync(`cp /tmp/prophunt-cli "${cliPath}" && chmod +x "${cliPath}"`);
                log('Auto-update: CLI updated');
              }
            } catch { /* CLI update optional */ }
            execSync('rm -f /tmp/prophunt-cli');
          }
          execSync(`rm -f "${installSh}"`);
        }
      } catch { /* optional */ }

      log('Auto-update: complete — restarting server');

      // Restart: re-launch and exit current process
      const startScript = join(PROJECT_ROOT, 'start-server.sh');
      if (existsSync(startScript)) {
        spawn(startScript, [], { detached: true, stdio: 'ignore' }).unref();
      } else {
        const nodeCmd = process.argv[0];
        const serverBundle = join(PROJECT_ROOT, 'server.bundle.cjs');
        spawn(nodeCmd, [serverBundle, ...(dryRun ? ['--dry-run'] : [])], { detached: true, stdio: 'ignore', cwd: PROJECT_ROOT }).unref();
      }
      setTimeout(() => process.exit(0), 1000);

    } catch (err) {
      execSync(`rm -f "${join(PROJECT_ROOT, 'server.bundle.cjs.tmp')}" 2>/dev/null || true`);
      log(`Auto-update: check failed — ${err.message}`);
    }
  }, 60000); // Check every minute
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
