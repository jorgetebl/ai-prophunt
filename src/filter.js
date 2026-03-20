import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import { log } from './logger.js';
import { isConfigured, getUserId, getContacts, contactExists, getTodayCount as sbGetTodayCount } from './supabase.js';

export const CONTACTED_PATH = join(import.meta.dirname, '..', 'data', 'contacted.json');

// --- JSON fallback ---

function loadContactedFromFile() {
  try {
    return JSON.parse(readFileSync(CONTACTED_PATH, 'utf-8'));
  } catch {
    return { contacts: [] };
  }
}

// --- Public API ---

export function loadContacted() {
  // Synchronous version for backward compat — reads from file
  return loadContactedFromFile();
}

export async function loadContactedAsync() {
  if (isConfigured()) {
    const userId = await getUserId();
    const contacts = await getContacts(userId);
    return { contacts };
  }
  return loadContactedFromFile();
}

// Heuristic patterns that indicate an agency listing
const AGENCY_DESCRIPTION_PATTERNS = [
  /\b(inmobiliaria|real\s+estate|consulting|properties|inversiones|servicios\s+inmobiliarios)\b/i,
  /\b(oficina|office)\s*:/i,
  /\bhonorarios\s+de\s+intermediaci[oó]n/i,
  /\bagencia\s+(act[uú]a|inmobiliaria)\b/i,
  /\bintermediaria\s+inmobiliaria\b/i,
  /\b(presenta\s+en\s+exclusiva|comercializa)\b/i,
  /\b(RE\/?MAX|Keller\s+Williams|Century\s*21|Engel\s+&\s+V[oö]lkers|Tecnocasa|Redpiso|Gilmar|Aelca|Vía\s+Ásista|Solvia|Haya|Servihabitat|VOPrivate|Coldwell\s+Banker|Sotheby|Donpiso|Alfa\s+Inmobiliaria|Look\s*&\s*Find|Comprarcasa|Best\s+House|Fincas\s+Corral)\b/i,
  /\bref(?:erencia)?[\s.:]+\w{2,}\d{3,}/i,
];

function looksLikeAgency(el) {
  // 1) externalReference is almost always an agency
  if (el.externalReference) return true;

  // 2) Check description for agency patterns
  const desc = el.description || '';
  for (const pattern of AGENCY_DESCRIPTION_PATTERNS) {
    if (pattern.test(desc)) return true;
  }

  return false;
}

export function filterParticulares(elements) {
  const particulares = [];
  const agencyCount = { byRef: 0, byDesc: 0 };

  for (const el of elements) {
    if (el.externalReference) {
      agencyCount.byRef++;
    } else if (looksLikeAgency(el)) {
      agencyCount.byDesc++;
    } else {
      particulares.push(el);
    }
  }

  const totalAgencies = agencyCount.byRef + agencyCount.byDesc;
  log(`Filter: ${particulares.length} particulares, ${totalAgencies} agencies discarded (${agencyCount.byRef} by ref, ${agencyCount.byDesc} by description)`);
  return particulares;
}

export async function deduplicateContacts(elements) {
  if (isConfigured()) {
    const userId = await getUserId();
    const unique = [];
    let duplicates = 0;
    for (const el of elements) {
      const url = `https://www.idealista.com/inmueble/${el.propertyCode}/`;
      const phone = el.phone || null;
      const exists = await contactExists(userId, phone ? `34${phone}` : null, url);
      if (exists) {
        duplicates++;
      } else {
        unique.push(el);
      }
    }
    log(`Dedup: ${unique.length} new, ${duplicates} already contacted`);
    return { unique, duplicates };
  }

  // JSON fallback
  const contacted = loadContactedFromFile();
  const knownUrls = new Set(contacted.contacts.map(c => c.url));
  const knownCodes = new Set(contacted.contacts.map(c => c.propertyCode).filter(Boolean));
  const unique = [];
  let duplicates = 0;

  for (const el of elements) {
    const url = `https://www.idealista.com/inmueble/${el.propertyCode}/`;
    if (knownUrls.has(url) || knownCodes.has(String(el.propertyCode))) {
      duplicates++;
      continue;
    }
    unique.push(el);
  }

  log(`Dedup: ${unique.length} new, ${duplicates} already contacted`);
  return { unique, duplicates };
}

export async function getTodayContactCount() {
  if (isConfigured()) {
    return await sbGetTodayCount(await getUserId());
  }
  // JSON fallback
  const contacted = loadContactedFromFile();
  const today = new Date().toLocaleDateString('sv-SE', { timeZone: 'Europe/Madrid' });
  return contacted.contacts.filter(c =>
    c.date_contacted && c.date_contacted.startsWith(today)
  ).length;
}
