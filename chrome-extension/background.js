const SERVER = 'http://localhost:3456';

let activeTabId = null;
let polling = false;

// ── Polling via chrome.alarms (survives MV3 service worker suspension) ───────

chrome.alarms.create('poll', { periodInMinutes: 0.05 }); // ~3 seconds

chrome.alarms.onAlarm.addListener((alarm) => {
  if (alarm.name === 'poll') poll();
});

// Also poll on startup and when woken up
chrome.runtime.onStartup.addListener(() => poll());
chrome.runtime.onInstalled.addListener(() => poll());

async function poll() {
  if (polling) return; // prevent overlapping polls
  polling = true;
  try {
    const res = await fetch(`${SERVER}/browser/next-task`);
    if (!res.ok) { polling = false; return; }
    const task = await res.json();

    if (task.type === 'idle') { polling = false; return; }

    if (task.type === 'navigate') {
      await doNavigate(task.url, task.taskId);
    } else if (task.type === 'extract_dom') {
      await doExtractDom(task.taskId);
    } else if (task.type === 'extract_links') {
      await doExtractLinks(task.taskId);
    } else if (task.type === 'click') {
      await doClick(task.hint, task.taskId);
    }
  } catch {
    // Server not running yet — silently ignore
  }
  polling = false;
}

// ── Actions ───────────────────────────────────────────────────────────────────

async function doNavigate(url, taskId) {
  return new Promise((resolve) => {
    function createNewTab() {
      chrome.tabs.create({ url, active: false }, (tab) => {
        activeTabId = tab.id;
        waitForLoad(tab.id, resolve, taskId);
      });
    }

    if (activeTabId) {
      // Check if the tab still exists before trying to update it
      chrome.tabs.get(activeTabId, (tab) => {
        if (chrome.runtime.lastError || !tab) {
          activeTabId = null;
          createNewTab();
        } else {
          chrome.tabs.update(activeTabId, { url }, (updated) => {
            if (chrome.runtime.lastError || !updated) {
              activeTabId = null;
              createNewTab();
            } else {
              waitForLoad(updated.id, resolve, taskId);
            }
          });
        }
      });
    } else {
      createNewTab();
    }
  });
}

function waitForLoad(tabId, resolve, taskId) {
  activeTabId = tabId;

  function listener(id, changeInfo) {
    if (id !== tabId || changeInfo.status !== 'complete') return;
    chrome.tabs.onUpdated.removeListener(listener);

    // Extra 3s for dynamic content
    setTimeout(async () => {
      // Capture the final URL after any redirects
      let finalUrl = null;
      try {
        const tab = await chrome.tabs.get(tabId);
        finalUrl = tab.url || null;
      } catch { /* tab may have closed */ }

      await fetch(`${SERVER}/browser/action-done`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ taskId, action: 'navigate', ok: true, finalUrl }),
      }).catch(() => {});
      resolve();
    }, 3000);
  }

  chrome.tabs.onUpdated.addListener(listener);

  // Timeout safety: 30s
  setTimeout(() => {
    chrome.tabs.onUpdated.removeListener(listener);
    fetch(`${SERVER}/browser/action-done`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ taskId, action: 'navigate', ok: false, error: 'timeout' }),
    }).catch(() => {});
    resolve();
  }, 30000);
}

async function doExtractLinks(taskId) {
  if (!activeTabId) {
    await fetch(`${SERVER}/browser/links`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ taskId, links: [] }),
    }).catch(() => {});
    return;
  }

  try {
    const results = await chrome.scripting.executeScript({
      target: { tabId: activeTabId },
      func: extractGmailThreadLinks,
    });

    const links = results?.[0]?.result || [];

    await fetch(`${SERVER}/browser/links`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ taskId, links }),
    }).catch(() => {});
  } catch (err) {
    await fetch(`${SERVER}/browser/links`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ taskId, links: [], error: err.message }),
    }).catch(() => {});
  }
}

async function doExtractDom(taskId) {
  if (!activeTabId) {
    await fetch(`${SERVER}/browser/dom`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ taskId, dom: '', error: 'no_active_tab' }),
    }).catch(() => {});
    return;
  }

  try {
    const results = await chrome.scripting.executeScript({
      target: { tabId: activeTabId },
      func: extractDomContent,
    });

    const dom = results?.[0]?.result || '';

    await fetch(`${SERVER}/browser/dom`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ taskId, dom }),
    }).catch(() => {});
  } catch (err) {
    await fetch(`${SERVER}/browser/dom`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ taskId, dom: '', error: err.message }),
    }).catch(() => {});
  }
}

async function doClick(hint, taskId) {
  if (!activeTabId) return;

  try {
    const results = await chrome.scripting.executeScript({
      target: { tabId: activeTabId },
      func: clickByHint,
      args: [hint],
    });

    const clicked = results?.[0]?.result || false;

    // Wait 4s for popup/modal to render after click
    await new Promise(r => setTimeout(r, 4000));

    // Extract DOM immediately after click so the popup content is captured
    let dom = '';
    try {
      const domResults = await chrome.scripting.executeScript({
        target: { tabId: activeTabId },
        func: extractDomContent,
      });
      dom = domResults?.[0]?.result || '';
    } catch { /* ignore */ }

    // Send action-done AND the post-click DOM together
    await fetch(`${SERVER}/browser/action-done`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ taskId, action: 'click', ok: clicked, dom }),
    }).catch(() => {});
  } catch (err) {
    await fetch(`${SERVER}/browser/action-done`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ taskId, action: 'click', ok: false, error: err.message }),
    }).catch(() => {});
  }
}

// ── Injected page functions ───────────────────────────────────────────────────

function extractGmailThreadLinks() {
  const seen = new Set();
  const links = [];

  // Gmail email rows in list/search view have class 'zA'
  const rows = document.querySelectorAll('tr.zA');
  rows.forEach(row => {
    // Each row has anchor elements — grab the first one pointing to mail.google.com
    const anchors = row.querySelectorAll('a[href]');
    for (const a of anchors) {
      const href = a.href;
      if (href && href.includes('mail.google.com') && !seen.has(href)) {
        seen.add(href);
        links.push(href);
        break;
      }
    }
  });

  // Fallback: any Gmail URL with a 16-char hex thread ID
  if (links.length === 0) {
    document.querySelectorAll('a[href*="mail.google.com"]').forEach(a => {
      const href = a.href;
      if (/\/[0-9a-f]{16}(\?|$|#|\/)/.test(href) && !seen.has(href)) {
        seen.add(href);
        links.push(href);
      }
    });
  }

  return links;
}

function extractDomContent() {
  const clone = document.body.cloneNode(true);

  // Remove noise
  for (const tag of ['script', 'style', 'svg', 'img', 'noscript', 'iframe']) {
    clone.querySelectorAll(tag).forEach(el => el.remove());
  }

  // Get text and trim to 15k chars
  const text = clone.innerText || clone.textContent || '';
  return text.replace(/\s{3,}/g, '\n\n').trim().slice(0, 15000);
}

function clickByHint(hint) {
  const lowerHint = hint.toLowerCase();
  // Also try common phone button variations
  const variations = [
    lowerHint,
    'ver teléfono', 'ver telefono', 'ver número', 'ver numero',
    'mostrar teléfono', 'mostrar telefono',
    'llamar', 'contactar por teléfono',
    'show phone', 'see phone',
  ];

  // Search buttons, links, spans, divs with role=button, and any clickable-looking element
  const selectors = 'button, a, [role="button"], input[type="button"], [class*="phone"], [class*="telefono"], [class*="contact"] button, [class*="contact"] a';
  const all = Array.from(document.querySelectorAll(selectors));

  for (const variation of variations) {
    const target = all.find(el => {
      const text = (el.textContent || el.value || el.getAttribute('aria-label') || '').toLowerCase().trim();
      return text.includes(variation);
    });
    if (target) {
      target.scrollIntoView({ block: 'center' });
      target.click();
      return true;
    }
  }

  // Fallback: try clicking any element whose text looks like a phone reveal button
  const fallback = all.find(el => {
    const text = (el.textContent || '').toLowerCase();
    return /tel[eé]fono|phone|llamar/.test(text) && !/ya has contactado/.test(text);
  });
  if (fallback) {
    fallback.scrollIntoView({ block: 'center' });
    fallback.click();
    return true;
  }

  return false;
}
