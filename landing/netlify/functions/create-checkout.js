import Stripe from 'stripe';
import { createClient } from '@supabase/supabase-js';

const stripe = new Stripe(process.env.STRIPE_SECRET_KEY);
const PRICES = {
  // Legacy (keep for existing subscribers)
  basico: process.env.STRIPE_PRICE_BASICO,
  pro: process.env.STRIPE_PRICE_PRO,
  // New zone-exclusivity plans
  agente: process.env.STRIPE_PRICE_AGENTE,
  oficina: process.env.STRIPE_PRICE_OFICINA,
  agencia: process.env.STRIPE_PRICE_AGENCIA,
};

const supabase = createClient(
  process.env.SUPABASE_URL,
  process.env.SUPABASE_SERVICE_KEY
);

export default async (req) => {
  if (req.method !== 'POST') {
    return new Response(JSON.stringify({ error: 'Method not allowed' }), { status: 405 });
  }

  // Auth: extract Supabase JWT
  const authHeader = req.headers.get('authorization') || '';
  const token = authHeader.replace('Bearer ', '').trim();
  if (!token) {
    return new Response(JSON.stringify({ error: 'Unauthorized' }), { status: 401 });
  }

  // Verify token and get user
  const { data: { user }, error: authErr } = await supabase.auth.getUser(token);
  if (authErr || !user) {
    return new Response(JSON.stringify({ error: 'Invalid token' }), { status: 401 });
  }

  // Parse body
  let plan;
  try {
    const body = await req.json();
    plan = body.plan;
  } catch {
    return new Response(JSON.stringify({ error: 'Invalid body' }), { status: 400 });
  }

  const priceId = PRICES[plan];
  if (!priceId) {
    return new Response(JSON.stringify({ error: `Unknown plan: ${plan}` }), { status: 400 });
  }

  // Get or create Stripe customer for this user
  let customerId;
  const { data: sub } = await supabase
    .from('subscriptions')
    .select('stripe_customer_id')
    .eq('user_id', user.id)
    .single();

  if (sub?.stripe_customer_id) {
    customerId = sub.stripe_customer_id;
  } else {
    const customer = await stripe.customers.create({
      email: user.email,
      metadata: { supabase_user_id: user.id },
    });
    customerId = customer.id;
  }

  // Create Checkout session
  const origin = req.headers.get('origin') || 'https://prophunt-app.netlify.app';
  const session = await stripe.checkout.sessions.create({
    customer: customerId,
    mode: 'subscription',
    payment_method_types: ['card'],
    line_items: [{ price: priceId, quantity: 1 }],
    allow_promotion_codes: true,
    success_url: `${origin}/dashboard.html?checkout=success`,
    cancel_url: `${origin}/?checkout=cancelled`,
    metadata: { supabase_user_id: user.id, plan },
  });

  return new Response(JSON.stringify({ url: session.url }), {
    status: 200,
    headers: { 'Content-Type': 'application/json' },
  });
};

export const config = { path: '/api/create-checkout' };
