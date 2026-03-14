/**
 * Claude API proxy client.
 * All calls go through the Netlify Function at /api/claude,
 * authenticated with the user's Supabase JWT.
 * The ANTHROPIC_API_KEY never leaves Netlify's environment.
 */

const PROXY_URL = process.env.CLAUDE_PROXY_URL || 'https://prophunt-app.netlify.app/api/claude';

let _accessToken = null;

/**
 * Set the Supabase access token used to authenticate proxy calls.
 * Called once after login from server.js.
 */
export function setAccessToken(token) {
  _accessToken = token;
}

async function callProxy(action, payload) {
  if (!_accessToken) {
    throw new Error('No Supabase access token set. Call setAccessToken() after login.');
  }

  const res = await fetch(PROXY_URL, {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      'Authorization': `Bearer ${_accessToken}`,
    },
    body: JSON.stringify({ action, payload }),
  });

  if (res.status === 401) throw new Error('Claude proxy: unauthorized — token expired?');
  if (res.status === 403) throw new Error('Claude proxy: no active subscription');
  if (!res.ok) {
    const err = await res.json().catch(() => ({}));
    throw new Error(`Claude proxy error: ${err.error || res.statusText}`);
  }

  const data = await res.json();
  return data.result;
}

/**
 * Parse a BetterPlace email and extract property listings.
 * @param {string} text - innerText of the email (max 12k chars)
 * @returns {Promise<Array<{url, zone, price, portal, isParticular}>>}
 */
export async function parseEmail(text) {
  return callProxy('parse_email', { text });
}

/**
 * Extract phone from property page DOM text.
 * @param {string} domText - cleaned innerText of the property page (max 14k chars)
 * @param {string} portal - 'idealista' | 'fotocasa' | 'pisos.com'
 * @returns {Promise<{found: boolean, phone?: string, action?: string, noPhone?: boolean}>}
 */
export async function extractPhone(domText, portal) {
  return callProxy('extract_phone', { domText, portal });
}

/**
 * Build a personalized WhatsApp message using Claude.
 * @param {Object} contact - {name, zone, portal, price, propertyType, detail}
 * @returns {Promise<string>}
 */
export async function buildMessage(contact) {
  return callProxy('build_message', { contact });
}
