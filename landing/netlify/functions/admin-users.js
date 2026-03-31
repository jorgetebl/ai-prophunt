import { createClient } from '@supabase/supabase-js';

const supabase = createClient(
  process.env.SUPABASE_URL,
  process.env.SUPABASE_SERVICE_KEY
);

const ADMIN_SECRET = process.env.ADMIN_SECRET;

export default async (req) => {
  if (req.method !== 'GET') {
    return new Response('Method not allowed', { status: 405 });
  }

  // Simple secret-based auth via header or query param
  const authHeader = req.headers.get('x-admin-secret');
  const url = new URL(req.url);
  const querySecret = url.searchParams.get('secret');
  if (!ADMIN_SECRET || (authHeader !== ADMIN_SECRET && querySecret !== ADMIN_SECRET)) {
    return new Response('Unauthorized', { status: 401 });
  }

  const { data, error } = await supabase
    .from('subscriptions')
    .select('user_id, plan, status, client_version, last_seen, created_at')
    .order('last_seen', { ascending: false, nullsFirst: false });

  if (error) {
    return new Response(JSON.stringify({ error: error.message }), {
      status: 500,
      headers: { 'Content-Type': 'application/json' },
    });
  }

  // Enrich with email from auth.users via admin API
  const { data: users } = await supabase.auth.admin.listUsers({ perPage: 1000 });
  const emailMap = {};
  if (users?.users) {
    for (const u of users.users) emailMap[u.id] = u.email;
  }

  const result = (data || []).map(row => ({
    user_id: row.user_id,
    email: emailMap[row.user_id] || null,
    plan: row.plan,
    status: row.status,
    client_version: row.client_version || null,
    last_seen: row.last_seen || null,
    created_at: row.created_at,
  }));

  return new Response(JSON.stringify(result, null, 2), {
    status: 200,
    headers: { 'Content-Type': 'application/json' },
  });
};

export const config = { path: '/api/admin/users' };
