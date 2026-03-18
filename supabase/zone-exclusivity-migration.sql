-- Zone Exclusivity Migration
-- Expands plan types, adds zone columns to configs, creates zone_licenses table

-- 1. Expand plan check constraint (keep basico/pro for legacy subscriptions like Juanan)
ALTER TABLE subscriptions DROP CONSTRAINT IF EXISTS subscriptions_plan_check;
ALTER TABLE subscriptions ADD CONSTRAINT subscriptions_plan_check
  CHECK (plan IN ('basico', 'pro', 'agente', 'oficina', 'agencia'));

-- 2. Add zone-related columns to configs
ALTER TABLE configs ADD COLUMN IF NOT EXISTS max_zones integer DEFAULT 1;
ALTER TABLE configs ADD COLUMN IF NOT EXISTS zones jsonb DEFAULT '[]'::jsonb;

-- 3. Create zone_licenses table for exclusivity enforcement
CREATE TABLE IF NOT EXISTS zone_licenses (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  zone_name text NOT NULL UNIQUE,
  user_id uuid REFERENCES auth.users(id) NOT NULL,
  created_at timestamptz DEFAULT now()
);

ALTER TABLE zone_licenses ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Users see all zone licenses" ON zone_licenses
  FOR SELECT USING (true);

CREATE POLICY "Users manage own zone licenses" ON zone_licenses
  FOR ALL USING (auth.uid() = user_id);

CREATE INDEX IF NOT EXISTS idx_zone_licenses_user ON zone_licenses(user_id);
CREATE INDEX IF NOT EXISTS idx_zone_licenses_zone ON zone_licenses(zone_name);
