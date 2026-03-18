import Stripe from 'stripe';
import { createClient } from '@supabase/supabase-js';

const stripe = new Stripe(process.env.STRIPE_SECRET_KEY);
const supabase = createClient(
  process.env.SUPABASE_URL,
  process.env.SUPABASE_SERVICE_KEY
);

export default async (req) => {
  if (req.method !== 'POST') {
    return new Response('Method not allowed', { status: 405 });
  }

  const sig = req.headers.get('stripe-signature');
  let rawBody;
  try {
    rawBody = await req.text();
  } catch {
    return new Response('Could not read body', { status: 400 });
  }

  let event;
  try {
    event = stripe.webhooks.constructEvent(rawBody, sig, process.env.STRIPE_WEBHOOK_SECRET);
  } catch (err) {
    console.error('Stripe webhook signature error:', err.message);
    return new Response(`Webhook Error: ${err.message}`, { status: 400 });
  }

  if (event.type === 'customer.subscription.created' || event.type === 'customer.subscription.updated') {
    const sub = event.data.object;
    const customerId = sub.customer;
    // Map price ID to plan name
    const priceId = sub.items?.data?.[0]?.price?.id;
    const PRICE_TO_PLAN = {
      [process.env.STRIPE_PRICE_PRO]: 'pro',
      [process.env.STRIPE_PRICE_BASICO]: 'basico',
      [process.env.STRIPE_PRICE_AGENTE]: 'agente',
      [process.env.STRIPE_PRICE_OFICINA]: 'oficina',
      [process.env.STRIPE_PRICE_AGENCIA]: 'agencia',
    };
    const PLAN_LIMITS = {
      basico:  { maxContacts: 15, maxZones: 1 },
      pro:     { maxContacts: 50, maxZones: 1 },
      agente:  { maxContacts: 20, maxZones: 1 },
      oficina: { maxContacts: 40, maxZones: 3 },
      agencia: { maxContacts: 60, maxZones: 6 },
    };
    const plan = PRICE_TO_PLAN[priceId] || 'basico';

    // Find user by customer ID (may already exist) or via checkout metadata
    let userId = null;
    const { data: existing } = await supabase
      .from('subscriptions')
      .select('user_id')
      .eq('stripe_customer_id', customerId)
      .single();

    if (existing?.user_id) {
      userId = existing.user_id;
    } else {
      // Try to find via Stripe customer metadata
      const customer = await stripe.customers.retrieve(customerId);
      userId = customer.metadata?.supabase_user_id || null;
    }

    if (userId) {
      await supabase.from('subscriptions').upsert({
        user_id: userId,
        stripe_customer_id: customerId,
        stripe_subscription_id: sub.id,
        plan,
        status: sub.status === 'active' ? 'active' : 'inactive',
        current_period_end: new Date(sub.current_period_end * 1000).toISOString(),
        updated_at: new Date().toISOString(),
      }, { onConflict: 'stripe_subscription_id' });

      // Update configs based on plan limits
      const limits = PLAN_LIMITS[plan] || PLAN_LIMITS.basico;
      await supabase.from('configs')
        .update({ max_contacts_per_day: limits.maxContacts, max_zones: limits.maxZones })
        .eq('user_id', userId);

      console.log(`Subscription upserted: ${userId} → ${plan} (${limits.maxContacts} contacts/day, ${limits.maxZones} zones)`);
    } else {
      console.warn(`No user found for Stripe customer ${customerId}`);
    }
  }

  if (event.type === 'customer.subscription.deleted') {
    const sub = event.data.object;
    await supabase
      .from('subscriptions')
      .update({ status: 'canceled', updated_at: new Date().toISOString() })
      .eq('stripe_subscription_id', sub.id);

    console.log(`Subscription canceled: ${sub.id}`);
  }

  return new Response(JSON.stringify({ received: true }), {
    status: 200,
    headers: { 'Content-Type': 'application/json' },
  });
};

export const config = { path: '/stripe/webhook' };
