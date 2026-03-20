import { readFileSync, writeFileSync, mkdirSync } from 'node:fs';
import { join } from 'node:path';
import { log } from './logger.js';

const BUDGET_PATH = join(import.meta.dirname, '..', 'data', 'request_budget.json');

function getCurrentMonth() {
  return new Date().toLocaleDateString('sv-SE', { timeZone: 'Europe/Madrid' }).slice(0, 7);
}

function loadBudget() {
  try {
    return JSON.parse(readFileSync(BUDGET_PATH, 'utf-8'));
  } catch {
    return { month: getCurrentMonth(), used: 0, limit: 100 };
  }
}

function saveBudget(budget) {
  mkdirSync(join(import.meta.dirname, '..', 'data'), { recursive: true });
  writeFileSync(BUDGET_PATH, JSON.stringify(budget, null, 2) + '\n');
}

function getWorkingDaysLeft() {
  const now = new Date();
  const madridDate = new Date(now.toLocaleString('en-US', { timeZone: 'Europe/Madrid' }));
  const year = madridDate.getFullYear();
  const month = madridDate.getMonth();
  const today = madridDate.getDate();
  const lastDay = new Date(year, month + 1, 0).getDate();
  let count = 0;
  for (let d = today; d <= lastDay; d++) {
    const day = new Date(year, month, d).getDay();
    if (day >= 1 && day <= 5) count++;
  }
  return count || 1; // At least 1 to avoid division by zero
}

export function getRequestsAvailableToday(config) {
  const budget = loadBudget();
  const currentMonth = getCurrentMonth();

  // Reset if new month
  if (budget.month !== currentMonth) {
    budget.month = currentMonth;
    budget.used = 0;
    budget.limit = config.idealista?.maxRequestsPerMonth || 100;
    saveBudget(budget);
  }

  const remaining = budget.limit - budget.used;
  if (remaining <= 0) return 0;

  const workingDaysLeft = getWorkingDaysLeft();
  const perDay = Math.floor(remaining / workingDaysLeft);
  const maxPerDay = config.idealista?.maxRequestsPerDay || 4;

  return Math.min(perDay, maxPerDay);
}

export function recordRequest() {
  const budget = loadBudget();
  const currentMonth = getCurrentMonth();

  if (budget.month !== currentMonth) {
    budget.month = currentMonth;
    budget.used = 0;
  }

  budget.used++;
  saveBudget(budget);
  return budget;
}

export async function searchProperties(token, config) {
  const available = getRequestsAvailableToday(config);

  if (available <= 0) {
    log('No API requests available today (budget exhausted)');
    return [];
  }

  log(`Requests available today: ${available}`);

  const idealista = config.idealista || {};
  const allElements = [];
  let requestsUsed = 0;
  let totalPages = 1; // Unknown until first response

  for (let page = 1; page <= available && page <= totalPages; page++) {
    const params = new URLSearchParams({
      operation: idealista.operation || 'sale',
      propertyType: idealista.propertyType || 'homes',
      locationId: idealista.locationId || '0-EU-ES-28',
      sinceDate: idealista.sinceDate || 'Y',
      maxItems: String(idealista.maxItems || 50),
      order: 'publicationDate',
      sort: 'desc',
      numPage: String(page),
    });

    log(`API request ${page}/${available}: searching page ${page}...`);

    const res = await fetch('https://api.idealista.com/3.5/es/search', {
      method: 'POST',
      headers: {
        'Authorization': `Bearer ${token}`,
        'Content-Type': 'application/x-www-form-urlencoded',
      },
      body: params.toString(),
    });

    const budget = recordRequest();
    requestsUsed++;

    if (!res.ok) {
      const text = await res.text();
      log(`API error (${res.status}): ${text}`);
      break;
    }

    const data = await res.json();
    const elements = data.elementList || [];
    allElements.push(...elements);

    totalPages = Math.ceil((data.total || 0) / (idealista.maxItems || 50));

    log(`Page ${page}: ${elements.length} results (total in API: ${data.total || 0}, budget used this month: ${budget.used}/${budget.limit})`);

    if (elements.length < (idealista.maxItems || 50)) {
      break; // Last page
    }
  }

  return { elements: allElements, requestsUsed };
}

// Allow running standalone: node src/search.js
if (import.meta.url === `file://${process.argv[1]}`) {
  (async () => {
    const { config: loadEnv } = await import('dotenv');
    loadEnv();
    const { getToken } = await import('./auth.js');
    const config = JSON.parse(readFileSync(join(import.meta.dirname, '..', 'config.json'), 'utf-8'));
    try {
      const token = await getToken();
      const result = await searchProperties(token, config);
      console.log(`\nFound ${result.elements.length} properties (${result.requestsUsed} requests used)`);
      for (const el of result.elements.slice(0, 5)) {
        console.log(`  - ${el.address} | ${el.price}€ | ref=${el.externalReference || 'none'} | ${el.url}`);
      }
      if (result.elements.length > 5) {
        console.log(`  ... and ${result.elements.length - 5} more`);
      }
    } catch (err) {
      console.error('Error:', err.message);
      process.exit(1);
    }
  })();
}
