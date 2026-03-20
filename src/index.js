import 'dotenv/config';
import { readFileSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { log } from './logger.js';
import { getToken } from './auth.js';
import { searchProperties, getRequestsAvailableToday } from './search.js';
import { filterParticulares, deduplicateContacts, getTodayContactCount } from './filter.js';

const CONFIG_PATH = join(import.meta.dirname, '..', 'config.json');
const PENDING_PATH = join(import.meta.dirname, '..', 'data', 'pending.json');

function loadConfig() {
  return JSON.parse(readFileSync(CONFIG_PATH, 'utf-8'));
}

function isWorkingDay(schedule) {
  const now = new Date();
  const madridDate = new Date(now.toLocaleString('en-US', { timeZone: schedule.timezone || 'Europe/Madrid' }));
  const dayOfWeek = madridDate.getDay();
  const workingDays = schedule.working_days || [1, 2, 3, 4, 5];
  return workingDays.includes(dayOfWeek);
}

async function main() {
  const config = loadConfig();

  log('=== ai-prophunt API search started ===');

  // 1. Check working day
  if (!isWorkingDay(config.schedule || {})) {
    log('Not a working day, exiting');
    process.exit(0);
  }

  // 2. Log daily contact count (send limit enforced by server, not here)
  const maxPerDay = config.filters?.max_contacts_per_day || 15;
  const todayCount = await getTodayContactCount();
  log(`Contacts today: ${todayCount}/${maxPerDay} (send limit enforced by server)`);

  // 3. Check API budget
  const requestsAvailable = getRequestsAvailableToday(config);
  if (requestsAvailable <= 0) {
    log('No API requests available this month, exiting');
    process.exit(0);
  }

  // 4. Get OAuth token
  const token = await getToken();

  // 5. Search properties
  const searchResult = await searchProperties(token, config);
  const { elements, requestsUsed } = searchResult;

  if (elements.length === 0) {
    log('No properties found');
    writeFileSync(PENDING_PATH, JSON.stringify({ properties: [], stats: { totalFound: 0, requestsUsed } }, null, 2) + '\n');
    process.exit(0);
  }

  log(`Total properties from API: ${elements.length}`);

  // 6. Filter particulares (agency === false)
  const particulares = filterParticulares(elements);

  // 7. Deduplicate against contacted.json
  const { unique, duplicates } = await deduplicateContacts(particulares);

  // 8. Build pending list (all non-agency, non-duplicate properties — server handles send limit)
  const pending = unique.map(el => ({
    propertyCode: String(el.propertyCode),
    url: `https://www.idealista.com/inmueble/${el.propertyCode}/`,
    address: el.address || '',
    district: el.district || '',
    municipality: el.municipality || '',
    province: el.province || '',
    price: el.price || 0,
    size: el.size || 0,
    rooms: el.rooms || 0,
    bathrooms: el.bathrooms || 0,
    floor: el.floor || '',
    propertyType: el.propertyType || '',
    description: (el.description || '').substring(0, 200),
  }));

  const output = {
    date: new Date().toISOString(),
    stats: {
      totalFound: elements.length,
      particulares: particulares.length,
      newProperties: unique.length,
      duplicates,
      pendingToProcess: pending.length,
      requestsUsed,
    },
    config: {
      validPhonePrefixes: config.filters?.valid_phone_prefixes || ['6', '7'],
      maxContactsPerDay: maxPerDay,
      slotsLeft,
      minDelayBetweenMessages: config.filters?.min_delay_between_messages_seconds || 120,
    },
    properties: pending,
  };

  writeFileSync(PENDING_PATH, JSON.stringify(output, null, 2) + '\n');

  log(`Pending file written: ${pending.length} properties to process`);
  log(`Stats: ${elements.length} total → ${particulares.length} particulares → ${unique.length} new → ${pending.length} pending`);
  log('=== API search finished ===');
}

main().catch(err => {
  log(`Fatal error: ${err.message}`);
  console.error(err);
  process.exit(1);
});
