"""Explicit additive migrations; old application images can still read the schema."""


def migrate_auth(conn):
    conn.execute("SELECT pg_advisory_xact_lock(hashtext('weekglass_schema'))")
    conn.execute('''CREATE TABLE IF NOT EXISTS schema_migrations (
      migration_id text PRIMARY KEY, applied_at timestamptz NOT NULL DEFAULT now())''')
    name = '20261106_account_recovery_v1'
    if not conn.execute('SELECT 1 FROM schema_migrations WHERE migration_id=%s', (name,)).fetchone():
        conn.execute('ALTER TABLE auth_accounts ADD COLUMN IF NOT EXISTS recovery_hash text')
        conn.execute('''ALTER TABLE auth_grants ADD COLUMN IF NOT EXISTS account_id uuid
          REFERENCES accounts(account_id) ON DELETE CASCADE''')
        conn.execute('INSERT INTO schema_migrations(migration_id) VALUES (%s)', (name,))

    migrate_email_identity(conn)
    migrate_paid_email_identity(conn)
    migrate_account_console(conn)


def migrate_account_console(conn):
    name = '20261116_account_console_v1'
    if conn.execute('SELECT 1 FROM schema_migrations WHERE migration_id=%s', (name,)).fetchone():
        return
    conn.execute('''
      CREATE TABLE web_sessions (
        session_hash text PRIMARY KEY,
        account_id uuid NOT NULL REFERENCES accounts(account_id) ON DELETE CASCADE,
        credential_version bigint NOT NULL,
        expires_at timestamptz NOT NULL
      );
      CREATE INDEX web_sessions_account ON web_sessions(account_id);
      CREATE INDEX web_sessions_expiry ON web_sessions(expires_at);

      ALTER TABLE auth_grants ADD COLUMN portal boolean NOT NULL DEFAULT false,
        ADD COLUMN portal_session_hash text,
        ADD CHECK (NOT portal OR (redirect_uri='' AND challenge='' AND state='')),
        ADD CHECK (portal_session_hash IS NULL OR (portal AND management_only));

      CREATE TABLE web_owner (
        singleton boolean PRIMARY KEY DEFAULT true CHECK (singleton),
        account_id uuid NOT NULL REFERENCES accounts(account_id) ON DELETE CASCADE
      );
      CREATE TABLE web_owner_actions (
        action_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
        actor_id uuid NOT NULL, subject_id uuid NOT NULL,
        action text NOT NULL CHECK (action IN ('suspend','resume','revoke_devices','revoke_device','change_grant')),
        days smallint CHECK (days BETWEEN 0 AND 366),
        occurred_at timestamptz NOT NULL DEFAULT now()
      );

      -- A claim freezes a boundary while the account is read/write gated.
      -- It stores only coordinates and completion, not a copy of user data.
      CREATE TABLE calendar_export_claims (
        account_id uuid NOT NULL REFERENCES accounts(account_id) ON DELETE CASCADE,
        ended_at timestamptz NOT NULL,
        export_id uuid UNIQUE NOT NULL,
        dataset_id uuid NOT NULL,
        sync_epoch uuid NOT NULL,
        boundary bigint NOT NULL,
        created_at timestamptz NOT NULL DEFAULT now(),
        delivered_at timestamptz,
        completed_at timestamptz CHECK (completed_at IS NULL OR delivered_at IS NOT NULL),
        PRIMARY KEY (account_id,ended_at)
      );
    ''')
    conn.execute('INSERT INTO schema_migrations(migration_id) VALUES (%s)', (name,))


def migrate_email_identity(conn):
    name = '20261115_email_identity_v1'
    if conn.execute('SELECT 1 FROM schema_migrations WHERE migration_id=%s', (name,)).fetchone():
        return
    conn.execute('''
      ALTER TABLE auth_accounts
        ADD COLUMN verified_email text UNIQUE,
        ADD COLUMN email_verified_at timestamptz,
        ADD COLUMN legacy_login boolean NOT NULL DEFAULT true,
        ADD COLUMN credential_version bigint NOT NULL DEFAULT 0,
        ADD CHECK ((verified_email IS NULL) = (email_verified_at IS NULL)),
        ADD CHECK (legacy_login OR verified_email IS NOT NULL);

      -- A draft signup is scoped to a PKCE grant. It does not reserve an
      -- email address or create a durable account before mailbox proof.
      CREATE TABLE auth_email_flows (
        grant_hash text PRIMARY KEY REFERENCES auth_grants(grant_hash) ON DELETE CASCADE,
        action text NOT NULL CHECK (action IN ('email_register_verify','email_otp_verify',
          'email_reset_verify','email_reset_finish','email_bind_send','email_bind_verify',
          'email_change_old_send','email_change_old_verify',
          'email_change_new_send','email_change_new_verify')),
        expires_at timestamptz NOT NULL,
        email text,
        account_id uuid REFERENCES accounts(account_id) ON DELETE CASCADE,
        credential_version bigint,
        password_hash text,
        code_nonce text,
        code_hash text,
        attempts integer NOT NULL DEFAULT 0 CHECK (attempts BETWEEN 0 AND 5),
        old_email text,
        old_code_nonce text,
        old_code_hash text,
        manage_expires_at timestamptz,
        CHECK ((account_id IS NULL) = (credential_version IS NULL))
      );
      CREATE INDEX auth_email_flows_account ON auth_email_flows(account_id);
    ''')
    conn.execute('INSERT INTO schema_migrations(migration_id) VALUES (%s)', (name,))


def migrate_paid_email_identity(conn):
    name = '20261115_paid_email_identity_v1'
    if conn.execute('SELECT 1 FROM schema_migrations WHERE migration_id=%s', (name,)).fetchone():
        return
    conn.execute('''
      ALTER TABLE auth_accounts
        ADD COLUMN pending_email text,
        ADD COLUMN pending_login_key text UNIQUE,
        DROP CONSTRAINT auth_accounts_check1,
        ADD CHECK (legacy_login OR verified_email IS NOT NULL OR pending_email IS NOT NULL),
        ADD CHECK ((pending_email IS NULL) = (pending_login_key IS NULL)),
        ADD CHECK (pending_email IS NULL OR (NOT legacy_login AND verified_email IS NULL));
      CREATE INDEX auth_accounts_pending_recovery ON auth_accounts(pending_email,recovery_hash)
        WHERE pending_email IS NOT NULL;

      ALTER TABLE auth_grants ADD COLUMN management_only boolean NOT NULL DEFAULT false;

      -- Enrollment no longer uses OTPs and the prior bind entry screen had
      -- no payment check. Discard those drafts, not accounts or sessions.
      DELETE FROM auth_email_flows WHERE action IN ('email_register_verify','email_bind_send');
      ALTER TABLE auth_email_flows
        DROP COLUMN password_hash,
        DROP CONSTRAINT auth_email_flows_action_check,
        ADD CHECK (action IN ('email_otp_verify','email_reset_verify','email_reset_finish',
          'email_manage_unverified','email_manage_unavailable','email_bind_verify',
          'email_change_old_send','email_change_old_verify','email_change_new_send','email_change_new_verify'));
    ''')
    conn.execute('INSERT INTO schema_migrations(migration_id) VALUES (%s)', (name,))


def migrate_billing(conn):
    # db.init_schema holds the schema advisory lock and owns the transaction.
    conn.execute('''CREATE TABLE IF NOT EXISTS schema_migrations (
      migration_id text PRIMARY KEY, applied_at timestamptz NOT NULL DEFAULT now())''')
    name = '20261113_billing_ledger_v1'
    if conn.execute('SELECT 1 FROM schema_migrations WHERE migration_id=%s', (name,)).fetchone():
        return
    conn.execute('''
      CREATE TABLE billing_agreements (
        agreement_id uuid PRIMARY KEY,
        account_id uuid REFERENCES accounts(account_id) ON DELETE SET NULL,
        provider text NOT NULL, merchant_id text NOT NULL, app_id text NOT NULL,
        provider_agreement_id text,
        plan_id text NOT NULL, terms_version text NOT NULL, template_id text NOT NULL,
        amount_minor integer NOT NULL CHECK (amount_minor > 0),
        currency text NOT NULL CHECK (currency = 'CNY'),
        period_seconds integer NOT NULL CHECK (period_seconds = 2592000),
        status text NOT NULL CHECK (status IN ('pending','active','canceling','canceled','expired')),
        consented_at timestamptz NOT NULL, signed_at timestamptz, expires_at timestamptz,
        stopped_at timestamptz, channel_ended_at timestamptz,
        UNIQUE (provider, provider_agreement_id)
      );
      CREATE INDEX billing_agreements_account ON billing_agreements(account_id, consented_at DESC);
      CREATE UNIQUE INDEX billing_one_open_agreement ON billing_agreements(account_id)
        WHERE status IN ('pending','active','canceling');

      -- One shared slot per account/coverage boundary, regardless of purchase mode.
      CREATE TABLE billing_renewals (
        renewal_id uuid PRIMARY KEY,
        account_id uuid REFERENCES accounts(account_id) ON DELETE SET NULL,
        cycle_end timestamptz,
        agreement_id uuid REFERENCES billing_agreements(agreement_id),
        status text NOT NULL CHECK (status IN ('ready','reserved','settled','skipped')),
        due_at timestamptz, window_end_at timestamptz,
        notice_delivered_at timestamptz, notice_reference text,
        channel_ready_at timestamptz,
        UNIQUE (account_id, cycle_end),
        CHECK (due_at IS NULL OR (window_end_at IS NOT NULL AND cycle_end IS NOT NULL
          AND due_at < window_end_at AND window_end_at <= cycle_end))
      );
      CREATE INDEX billing_renewals_due ON billing_renewals(due_at) WHERE status='ready';

      CREATE TABLE billing_orders (
        checkout_id uuid PRIMARY KEY, -- also the stable merchant order number (UUID hex on the wire)
        account_id uuid REFERENCES accounts(account_id) ON DELETE SET NULL,
        renewal_id uuid NOT NULL REFERENCES billing_renewals(renewal_id),
        agreement_id uuid REFERENCES billing_agreements(agreement_id),
        source text NOT NULL CHECK (source IN ('checkout','renewal')),
        purchase_mode text NOT NULL CHECK (purchase_mode IN ('single','auto_renew')),
        provider text NOT NULL, merchant_id text NOT NULL, app_id text NOT NULL,
        provider_payment_id text,
        plan_id text NOT NULL, terms_version text NOT NULL,
        amount_minor integer NOT NULL CHECK (amount_minor > 0),
        currency text NOT NULL CHECK (currency = 'CNY'),
        period_seconds integer NOT NULL CHECK (period_seconds = 2592000),
        status text NOT NULL CHECK (status IN ('pending','submitting','processing','paid',
          'closed','failed','refund_pending','refunded')),
        created_at timestamptz NOT NULL, paid_at timestamptz,
        refund_required boolean NOT NULL DEFAULT false,
        UNIQUE (provider, provider_payment_id),
        CHECK ((agreement_id IS NOT NULL) = (purchase_mode = 'auto_renew')),
        CHECK ((provider_payment_id IS NOT NULL) = (paid_at IS NOT NULL))
      );
      ALTER TABLE billing_renewals ADD COLUMN order_id uuid REFERENCES billing_orders(checkout_id);
      ALTER TABLE billing_renewals ADD CHECK ((order_id IS NOT NULL) = (status IN ('reserved','settled')));
      CREATE INDEX billing_orders_account ON billing_orders(account_id,created_at DESC);
      CREATE INDEX billing_orders_agreement ON billing_orders(agreement_id) WHERE agreement_id IS NOT NULL;
      CREATE UNIQUE INDEX billing_one_unresolved_order ON billing_orders(account_id)
        WHERE status IN ('pending','submitting','processing');

      -- A coalesced checkout can have multiple keys, each with its own original intent.
      CREATE TABLE billing_checkout_keys (
        account_id uuid NOT NULL REFERENCES accounts(account_id) ON DELETE CASCADE,
        idempotency_key uuid NOT NULL,
        checkout_id uuid NOT NULL REFERENCES billing_orders(checkout_id),
        requested_terms_version text,
        PRIMARY KEY (account_id,idempotency_key)
      );
      CREATE TABLE billing_checkout_handoffs (
        ticket_hash text PRIMARY KEY,
        checkout_id uuid NOT NULL REFERENCES billing_orders(checkout_id),
        expires_at timestamptz NOT NULL,
        consumed_at timestamptz
      );
      CREATE INDEX billing_handoff_order ON billing_checkout_handoffs(checkout_id);

      CREATE TABLE billing_events (
        provider text NOT NULL, merchant_id text NOT NULL, app_id text NOT NULL,
        event_id text NOT NULL, related_id uuid NOT NULL,
        event_data jsonb NOT NULL,
        status text NOT NULL CHECK (status IN ('deferred','applied','rejected')),
        received_at timestamptz NOT NULL, processed_at timestamptz,
        PRIMARY KEY (provider,merchant_id,app_id,event_id)
      );
      CREATE INDEX billing_deferred_events ON billing_events(related_id,received_at)
        WHERE status='deferred';
      CREATE TABLE billing_refunds (
        provider text NOT NULL, merchant_id text NOT NULL, app_id text NOT NULL,
        merchant_refund_id text NOT NULL, provider_refund_id text NOT NULL,
        checkout_id uuid NOT NULL REFERENCES billing_orders(checkout_id),
        amount_minor integer NOT NULL CHECK (amount_minor > 0),
        status text NOT NULL CHECK (status IN ('pending','succeeded','failed')),
        PRIMARY KEY (provider,merchant_id,app_id,merchant_refund_id),
        UNIQUE (provider,provider_refund_id)
      );
      CREATE INDEX billing_refunds_order ON billing_refunds(checkout_id);
      CREATE TABLE billing_periods (
        checkout_id uuid PRIMARY KEY REFERENCES billing_orders(checkout_id),
        account_id uuid REFERENCES accounts(account_id) ON DELETE SET NULL,
        start_at timestamptz NOT NULL, end_at timestamptz NOT NULL, revoked_at timestamptz,
        CHECK (end_at-start_at = interval '720 hours')
      );
      CREATE INDEX billing_periods_account ON billing_periods(account_id,end_at);
    ''')
    conn.execute('INSERT INTO schema_migrations(migration_id) VALUES (%s)', (name,))


def migrate_provider_checkout(conn):
    name = '20261113_billing_checkout_session_v1'
    if conn.execute('SELECT 1 FROM schema_migrations WHERE migration_id=%s', (name,)).fetchone():
        return
    conn.execute('''ALTER TABLE billing_orders
      ADD COLUMN provider_checkout_url text,
      ADD COLUMN provider_checkout_expires_at timestamptz''')
    conn.execute('INSERT INTO schema_migrations(migration_id) VALUES (%s)', (name,))


def migrate_provider_reconcile(conn):
    name = '20261114_billing_reconciliation_v1'
    if conn.execute('SELECT 1 FROM schema_migrations WHERE migration_id=%s', (name,)).fetchone():
        return
    conn.execute('''ALTER TABLE billing_orders ADD COLUMN provider_next_check_at timestamptz;
      CREATE INDEX billing_provider_check_due ON billing_orders(provider,merchant_id,app_id,provider_next_check_at)
        WHERE status IN ('submitting','processing')''')
    conn.execute('INSERT INTO schema_migrations(migration_id) VALUES (%s)', (name,))


def migrate_billing_plan_periods(conn):
    name = '20261114_billing_plan_periods_v1'
    if conn.execute('SELECT 1 FROM schema_migrations WHERE migration_id=%s', (name,)).fetchone():
        return
    conn.execute('''
      ALTER TABLE billing_orders ADD COLUMN provider_product_id text,
        DROP CONSTRAINT billing_orders_period_seconds_check,
        ADD CONSTRAINT billing_orders_supported_period CHECK (
          period_seconds = 2592000 OR (period_seconds = 31536000 AND provider = 'waffo_pancake'
            AND source = 'checkout' AND purchase_mode = 'single' AND provider_product_id IS NOT NULL));
      ALTER TABLE billing_periods DROP CONSTRAINT billing_periods_check,
        ADD CONSTRAINT billing_periods_supported_length CHECK (
          end_at-start_at IN (interval '720 hours', interval '8760 hours'));
    ''')
    conn.execute('INSERT INTO schema_migrations(migration_id) VALUES (%s)', (name,))
