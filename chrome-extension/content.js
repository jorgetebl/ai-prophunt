// Passive content script — listens for messages from background.js
chrome.runtime.onMessage.addListener((msg, _sender, sendResponse) => {
  if (msg.type === 'get_dom') {
    const clone = document.body.cloneNode(true);
    for (const tag of ['script', 'style', 'svg', 'img', 'noscript', 'iframe']) {
      clone.querySelectorAll(tag).forEach(el => el.remove());
    }
    const text = (clone.innerText || clone.textContent || '')
      .replace(/\s{3,}/g, '\n\n')
      .trim()
      .slice(0, 15000);
    sendResponse({ dom: text });
  }
  return true; // keep channel open for async
});
