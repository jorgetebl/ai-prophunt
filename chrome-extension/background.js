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
    if (activeTabId) {
      chrome.tabs.update(activeTabId, { url }, (tab) => {
        waitForLoad(tab ? tab.id : activeTabId, resolve, taskId);
      });
    } else {
      chrome.tabs.create({ url, active: false }, (tab) => {
        activeTabId = tab.id;
        waitForLoad(tab.id, resolve, taskId);
      });
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
      await fetch(`${SERVER}/browser/action-done`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ taskId, action: 'navigate', ok: true }),
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

    // Wait 2s for DOM update after click
    await new Promise(r => setTimeout(r, 2000));

    await fetch(`${SERVER}/browser/action-done`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ taskId, action: 'click', ok: clicked }),
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
  const all = Array.from(document.querySelectorAll('button, a, [role="button"], input[type="button"]'));

  const target = all.find(el => {
    const text = (el.textContent || el.value || el.getAttribute('aria-label') || '').toLowerCase();
    return text.includes(lowerHint);
  });

  if (target) {
    target.click();
    return true;
  }
  return false;
}
