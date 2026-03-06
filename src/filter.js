import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import { log } from './logger.js';

export const CONTACTED_PATH = join(import.meta.dirname, '..', 'data', 'contacted.json');

export function loadContacted() {
  try {
    return JSON.parse(readFileSync(CONTACTED_PATH, 'utf-8'));
  } catch {
    return { contacts: [] };
  }
}

export function filterParticulares(elements) {
  const particulares = elements.filter(el => el.agency === false);
  const agencies = elements.length - particulares.length;
  log(`Filter: ${particulares.length} particulares, ${agencies} agencies discarded`);
  return particulares;
}

export function deduplicateContacts(elements) {
  const contacted = loadContacted();

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

export function getTodayContactCount() {
  const contacted = loadContacted();
  const today = new Date().toLocaleDateString('sv-SE', { timeZone: 'Europe/Madrid' });
  return contacted.contacts.filter(c =>
    c.date_contacted && c.date_contacted.startsWith(today)
  ).length;
}
