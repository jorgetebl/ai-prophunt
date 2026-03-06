import { execFile } from 'node:child_process';
import { readFileSync, writeFileSync } from 'node:fs';
import { log } from './logger.js';
import { loadContacted, CONTACTED_PATH } from './filter.js';
import { buildMessage } from './message.js';

const TICK_INTERVAL_MS = 10_000;

/**
 * Create a rate-limited send queue.
 * @param {object} config - Parsed config.json
 * @param {object} opts
 * @param {boolean} opts.dryRun - If true, skip wacli and register as dry_run
 * @returns {{ enqueue, getState, pause, resume, shutdown }}
 */
export function createQueue(config, { dryRun = false } = {}) {
  const items = [];
  let processing = false;
  let paused = false;
  let lastSendTime = 0;
  let shuttingDown = false;
  let timer = null;

  const minDelay = (config.filters?.min_delay_between_messages_seconds ?? 120) * 1000;
  const maxPerDay = config.filters?.max_contacts_per_day ?? 15;

  function getTodayCount() {
    const contacted = loadContacted();
    const today = new Date().toLocaleDateString('sv-SE', { timeZone: 'Europe/Madrid' });
    return contacted.contacts.filter(c =>
      c.date_contacted && c.date_contacted.startsWith(today)
    ).length;
  }

  function isWithinSchedule() {
    const now = new Date();
    const madridTime = new Date(now.toLocaleString('en-US', { timeZone: 'Europe/Madrid' }));
    const h = madridTime.getHours();
    const m = madridTime.getMinutes();
    const t = h * 60 + m;
    // 9:00-14:00 or 16:00-20:00
    return (t >= 540 && t < 840) || (t >= 960 && t < 1200);
  }

  function isDuplicate(contact) {
    const contacted = loadContacted();
    const knownPhones = new Set(contacted.contacts.map(c => c.phone));
    const knownUrls = new Set(contacted.contacts.map(c => c.url));
    if (knownPhones.has(`34${contact.phone}`) || knownPhones.has(contact.phone)) return true;
    if (contact.url && knownUrls.has(contact.url)) return true;
    return false;
  }

  function saveContact(contact, status, messagePreview) {
    const contacted = loadContacted();
    contacted.contacts.push({
      phone: `34${contact.phone}`,
      name: contact.name || '',
      url: contact.url,
      propertyCode: contact.propertyCode || '',
      portal: contact.portal,
      zone: contact.zone || '',
      price: contact.price || null,
      date_contacted: new Date().toISOString(),
      status,
      message_preview: messagePreview.slice(0, 80),
    });
    writeFileSync(CONTACTED_PATH, JSON.stringify(contacted, null, 2) + '\n');
  }

  function sendViaWacli(phone, message) {
    return new Promise((resolve, reject) => {
      execFile('wacli', ['send', 'text', '--to', `34${phone}`, '--message', message], (err, stdout, stderr) => {
        if (err) {
          reject(new Error(stderr || err.message));
        } else {
          resolve(stdout);
        }
      });
    });
  }

  async function processNext() {
    if (items.length === 0) return;
    processing = true;

    const contact = items.shift();
    log(`Queue: processing ${contact.phone} (${contact.url})`);

    try {
      // Double-check duplicate
      if (isDuplicate(contact)) {
        log(`Queue: ${contact.phone} is duplicate, skipping`);
        processing = false;
        return;
      }

      const message = buildMessage(contact);

      if (dryRun) {
        log(`Queue [DRY RUN]: would send to 34${contact.phone}`);
        saveContact(contact, 'dry_run', message);
      } else {
        await sendViaWacli(contact.phone, message);
        log(`Queue: sent to 34${contact.phone}`);
        saveContact(contact, 'sent', message);
      }

      lastSendTime = Date.now();
    } catch (err) {
      log(`Queue: failed to send to 34${contact.phone} — ${err.message}`);
      saveContact(contact, 'failed', err.message);
    }

    processing = false;
  }

  function tick() {
    if (paused || processing || items.length === 0 || shuttingDown) return;

    if (!isWithinSchedule()) {
      return; // Outside working hours
    }

    if (getTodayCount() >= maxPerDay) {
      log('Queue: daily limit reached, pausing until tomorrow');
      return;
    }

    if (Date.now() - lastSendTime < minDelay) {
      return; // Still within delay window
    }

    processNext();
  }

  // Start tick loop
  timer = setInterval(tick, TICK_INTERVAL_MS);

  return {
    enqueue(contact) {
      items.push(contact);
      log(`Queue: enqueued ${contact.phone} — position ${items.length}`);
      return { position: items.length };
    },

    getState() {
      return {
        queueLength: items.length,
        processing,
        paused,
        shuttingDown,
        lastSendTime: lastSendTime ? new Date(lastSendTime).toISOString() : null,
        todayCount: getTodayCount(),
        maxPerDay,
        dryRun,
        withinSchedule: isWithinSchedule(),
        items: items.map((c, i) => ({
          position: i + 1,
          phone: c.phone,
          url: c.url,
          portal: c.portal,
        })),
      };
    },

    pause() {
      paused = true;
      log('Queue: paused');
    },

    resume() {
      paused = false;
      log('Queue: resumed');
    },

    shutdown() {
      return new Promise((resolve) => {
        shuttingDown = true;
        log('Queue: shutting down...');

        if (timer) clearInterval(timer);

        // Wait for current processing to finish
        const check = setInterval(() => {
          if (!processing) {
            clearInterval(check);
            log(`Queue: shutdown complete. ${items.length} items remaining in queue.`);
            resolve();
          }
        }, 500);
      });
    },
  };
}
