import { createClient } from '@supabase/supabase-js';

let supabase = null;
let cachedUserId = null;

/**
 * Returns the Supabase client (service_role, bypasses RLS) or null if not configured.
 * Reads env vars lazily so dotenv has time to load.
 */
export function getSupabase() {
  if (supabase) return supabase;
  const url = process.env.SUPABASE_URL;
  const key = process.env.SUPABASE_SERVICE_ROLE_KEY;
  if (!url || !key) return null;
  supabase = createClient(url, key);
  return supabase;
}

/**
 * Resolves the user_id automatically:
 * 1. From PROPHUNT_USER_ID env var (if set explicitly)
 * 2. By authenticating with PROPHUNT_EMAIL + PROPHUNT_PASSWORD
 * 3. By picking the only user in auth.users (single-tenant)
 * Result is cached after first resolution.
 */
export async function getUserId() {
  if (cachedUserId) return cachedUserId;

  // 1. Explicit env var
  if (process.env.PROPHUNT_USER_ID) {
    cachedUserId = process.env.PROPHUNT_USER_ID;
    return cachedUserId;
  }

  const sb = getSupabase();
  if (!sb) return null;

  // 2. Auth with email + password
  const email = process.env.PROPHUNT_EMAIL;
  const password = process.env.PROPHUNT_PASSWORD;
  if (email && password) {
    const { data, error } = await sb.auth.signInWithPassword({ email, password });
    if (!error && data?.user?.id) {
      cachedUserId = data.user.id;
      return cachedUserId;
    }
    console.error('supabase auth:', error?.message || 'no user returned');
  }

  // 3. Single-tenant: pick the only user (via service_role)
  const { data: { users }, error } = await sb.auth.admin.listUsers({ page: 1, perPage: 1 });
  if (!error && users?.length === 1) {
    cachedUserId = users[0].id;
    return cachedUserId;
  }

  return null;
}

export function isConfigured() {
  return !!(process.env.SUPABASE_URL && process.env.SUPABASE_SERVICE_ROLE_KEY);
}

/**
 * Call once at startup to resolve and cache the user_id.
 * Returns true if Supabase is ready to use.
 */
export async function init() {
  if (!isConfigured()) return false;
  const userId = await getUserId();
  return !!userId;
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
