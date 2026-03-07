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

export function filterParticulares(elements) {
  const particulares = elements.filter(el => el.agency === false);
  const agencies = elements.length - particulares.length;
  log(`Filter: ${particulares.length} particulares, ${agencies} agencies discarded`);
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
