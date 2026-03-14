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
    const plan = sub.items?.data?.[0]?.price?.id === process.env.STRIPE_PRICE_PRO ? 'pro' : 'basico';

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

      console.log(`Subscription upserted: ${userId} → ${plan}`);
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
