import { createClient } from '@supabase/supabase-js';

let supabase = null;
let cachedUserId = null;

/**
 * Returns the Supabase client (anon key + user auth session) or null if not configured.
 * Reads env vars lazily so dotenv has time to load.
 */
export function getSupabase() {
  if (supabase) return supabase;
  const url = process.env.SUPABASE_URL;
  const key = process.env.SUPABASE_ANON_KEY;
  if (!url || !key) return null;
  supabase = createClient(url, key);
  return supabase;
}

/**
 * Returns the cached user_id (set during init).
 */
export async function getUserId() {
  return cachedUserId;
}

export function isConfigured() {
  return !!(process.env.SUPABASE_URL && process.env.SUPABASE_ANON_KEY);
}

/**
 * Call once at startup. Signs in with email+password to establish
 * an authenticated session. All subsequent operations use RLS.
 * Returns true if Supabase is ready to use.
 */
export async function init() {
  if (!isConfigured()) return false;

  const sb = getSupabase();
  if (!sb) return false;

  const email = process.env.PROPHUNT_EMAIL;
  const password = process.env.PROPHUNT_PASSWORD;
  if (!email || !password) {
    console.error('supabase: PROPHUNT_EMAIL y PROPHUNT_PASSWORD requeridos en .env');
    return false;
  }

  const { data, error } = await sb.auth.signInWithPassword({ email, password });
  if (error) {
    console.error('supabase auth:', error.message);
    return false;
  }

  cachedUserId = data.user.id;
  return true;
}

// --- Contacts ---

export async function getContacts(userId, { date, since } = {}) {
  const sb = getSupabase();
  if (!sb) return [];
  let query = sb.from('contacts').select('*').eq('user_id', userId).order('date_contacted', { ascending: false });
  if (date) {
    query = query.gte('date_contacted', date + 'T00:00:00').lt('date_contacted', date + 'T23:59:59.999');
  } else if (since) {
    query = query.gte('date_contacted', since);
  }
  const { data, error } = await query;
  if (error) { console.error('supabase getContacts:', error.message); return []; }
  return data || [];
}

export async function addContact(userId, contact) {
  const sb = getSupabase();
  if (!sb) return null;
  const { data, error } = await sb.from('contacts').insert({
    user_id: userId,
    phone: contact.phone,
    name: contact.name || null,
    url: contact.url || null,
    property_code: contact.propertyCode || null,
    portal: contact.portal || null,
    zone: contact.zone || null,
    price: contact.price || null,
    property_type: contact.property_type || null,
    detail: contact.detail || null,
    status: contact.status || 'sent',
    message_preview: contact.message_preview || null,
    date_contacted: contact.date_contacted || new Date().toISOString(),
  }).select().single();
  if (error) { console.error('supabase addContact:', error.message); return null; }
  return data;
}

export async function contactExists(userId, phone, url) {
  const sb = getSupabase();
  if (!sb) return false;
  // Check by phone
  if (phone) {
    const { count } = await sb.from('contacts').select('id', { count: 'exact', head: true })
      .eq('user_id', userId).eq('phone', phone);
    if (count > 0) return true;
  }
  // Check by URL
  if (url) {
    const { count } = await sb.from('contacts').select('id', { count: 'exact', head: true })
      .eq('user_id', userId).eq('url', url);
    if (count > 0) return true;
  }
  return false;
}

export async function getTodayCount(userId) {
  const sb = getSupabase();
  if (!sb) return 0;
  const today = new Date().toLocaleDateString('sv-SE', { timeZone: 'Europe/Madrid' });
  const { count, error } = await sb.from('contacts').select('id', { count: 'exact', head: true })
    .eq('user_id', userId).gte('date_contacted', today + 'T00:00:00');
  if (error) { console.error('supabase getTodayCount:', error.message); return 0; }
  return count || 0;
}

// --- Logs ---

export async function addLog(userId, message, level = 'info') {
  const sb = getSupabase();
  if (!sb) return;
  await sb.from('logs').insert({ user_id: userId, message, level });
}

export async function getLogs(userId, date) {
  const sb = getSupabase();
  if (!sb) return [];
  const { data, error } = await sb.from('logs').select('*')
    .eq('user_id', userId)
    .gte('created_at', date + 'T00:00:00')
    .lt('created_at', date + 'T23:59:59.999')
    .order('created_at', { ascending: true });
  if (error) { console.error('supabase getLogs:', error.message); return []; }
  return data || [];
}

// --- Config ---

export async function getConfig(userId) {
  const sb = getSupabase();
  if (!sb) return null;
  const { data, error } = await sb.from('configs').select('*').eq('user_id', userId).single();
  if (error) return null;
  return data;
}
