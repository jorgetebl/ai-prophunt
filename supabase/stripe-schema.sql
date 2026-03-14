-- Stripe subscriptions table
create table if not exists subscriptions (
  user_id uuid primary key references auth.users(id) on delete cascade,
  stripe_customer_id text unique,
  stripe_subscription_id text unique,
  plan text check (plan in ('basico', 'pro')),
  status text default 'active',
  current_period_end timestamptz,
  created_at timestamptz default now(),
  updated_at timestamptz default now()
);

alter table subscriptions enable row level security;

create policy "Users see own subscription" on subscriptions
  for all using (auth.uid() = user_id);

-- Function to check if a user has an active subscription
create or replace function has_active_subscription(uid uuid)
returns boolean language sql security definer as $$
  select exists (
    select 1 from subscriptions
    where user_id = uid
    and status = 'active'
    and current_period_end > now()
  );
$$;

-- Index for Stripe lookups
create index if not exists idx_subscriptions_stripe_customer on subscriptions(stripe_customer_id);
create index if not exists idx_subscriptions_stripe_sub on subscriptions(stripe_subscription_id);
