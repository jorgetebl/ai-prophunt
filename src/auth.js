import { log } from './logger.js';

let cachedToken = null;
let expiresAt = 0;

export async function getToken() {
  const now = Date.now();

  // Return cached token if still valid (with 5 min margin)
  if (cachedToken && now < expiresAt - 5 * 60 * 1000) {
    return cachedToken;
  }

  const apiKey = process.env.IDEALISTA_API_KEY;
  const secret = process.env.IDEALISTA_SECRET;

  if (!apiKey || !secret) {
    throw new Error('IDEALISTA_API_KEY and IDEALISTA_SECRET must be set in .env');
  }

  const credentials = Buffer.from(`${apiKey}:${secret}`).toString('base64');

  log('Requesting new OAuth token from Idealista...');

  const res = await fetch('https://api.idealista.com/oauth/token', {
    method: 'POST',
    headers: {
      'Authorization': `Basic ${credentials}`,
      'Content-Type': 'application/x-www-form-urlencoded',
    },
    body: 'grant_type=client_credentials&scope=read',
  });

  if (!res.ok) {
    const text = await res.text();
    throw new Error(`OAuth token request failed (${res.status}): ${text}`);
  }

  const data = await res.json();
  cachedToken = data.access_token;
  expiresAt = now + data.expires_in * 1000;

  log(`Token obtained, expires in ${Math.round(data.expires_in / 3600)}h`);

  return cachedToken;
}

// Allow running standalone: node src/auth.js
if (import.meta.url === `file://${process.argv[1]}`) {
  const { config } = await import('dotenv');
  config();
  try {
    const token = await getToken();
    console.log('Token obtained successfully');
    console.log(`Token (first 20 chars): ${token.substring(0, 20)}...`);
  } catch (err) {
    console.error('Error:', err.message);
    process.exit(1);
  }
}
