-- Energy Insights Platform - Initial PostgreSQL Schema
-- Migration: 001_init_schema
--
-- Core principles:
-- - Multi-tenant SaaS: all domain data is scoped to tenant_id.
-- - UUID primary keys (pgcrypto gen_random_uuid()).
-- - Designed to be API-first and extensible (JSONB metadata/payloads where appropriate).
-- - Constraints and indexes to support common query patterns and prevent duplicates.
--
-- Applied by: database/migrate.sh (tracked in schema_migrations).

BEGIN;

-- -----------------------------------------------------------------------------
-- Extensions
-- -----------------------------------------------------------------------------
CREATE EXTENSION IF NOT EXISTS pgcrypto;

-- -----------------------------------------------------------------------------
-- Migrations tracking (also ensured by migrate.sh, but safe to have here too)
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS schema_migrations (
    version         TEXT PRIMARY KEY,
    applied_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- -----------------------------------------------------------------------------
-- Utility: updated_at trigger function
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION set_updated_at()
RETURNS TRIGGER AS $$
BEGIN
  NEW.updated_at = now();
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- -----------------------------------------------------------------------------
-- Tenancy
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS tenants (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    name            TEXT NOT NULL,
    slug            TEXT NOT NULL,
    status          TEXT NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'suspended', 'deleted')),
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Tenant slugs are typically globally unique in multi-tenant SaaS.
CREATE UNIQUE INDEX IF NOT EXISTS ux_tenants_slug ON tenants (lower(slug));

DROP TRIGGER IF EXISTS trg_tenants_set_updated_at ON tenants;
CREATE TRIGGER trg_tenants_set_updated_at
BEFORE UPDATE ON tenants
FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- -----------------------------------------------------------------------------
-- Users and roles
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS users (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id       UUID NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
    email           TEXT NOT NULL,
    full_name       TEXT,
    -- auth_subject is an external identity reference (e.g., "auth0|...", "supabase|...", "cognito|...")
    auth_subject    TEXT,
    status          TEXT NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'invited', 'disabled')),
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    last_login_at   TIMESTAMPTZ,
    CONSTRAINT chk_users_email_nonempty CHECK (length(trim(email)) > 3)
);

-- Enforce email uniqueness per tenant (case-insensitive).
CREATE UNIQUE INDEX IF NOT EXISTS ux_users_tenant_email ON users (tenant_id, lower(email));
CREATE INDEX IF NOT EXISTS ix_users_tenant ON users (tenant_id);
CREATE INDEX IF NOT EXISTS ix_users_auth_subject ON users (auth_subject);

DROP TRIGGER IF EXISTS trg_users_set_updated_at ON users;
CREATE TRIGGER trg_users_set_updated_at
BEFORE UPDATE ON users
FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- Roles are global (not tenant-scoped) to enable consistent authorization policy.
CREATE TABLE IF NOT EXISTS roles (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    name            TEXT NOT NULL,
    description     TEXT,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT chk_roles_name_nonempty CHECK (length(trim(name)) > 0)
);

CREATE UNIQUE INDEX IF NOT EXISTS ux_roles_name ON roles (lower(name));

-- Join table: assigns roles to users within a tenant.
-- Note: users already have tenant_id; we duplicate tenant_id here to:
--   1) enforce tenant-scoped assignments,
--   2) enable fast tenant filtering without joining users.
CREATE TABLE IF NOT EXISTS user_roles (
    tenant_id       UUID NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
    user_id         UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    role_id         UUID NOT NULL REFERENCES roles(id) ON DELETE CASCADE,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (tenant_id, user_id, role_id)
);

CREATE INDEX IF NOT EXISTS ix_user_roles_user ON user_roles (user_id);
CREATE INDEX IF NOT EXISTS ix_user_roles_role ON user_roles (role_id);
CREATE INDEX IF NOT EXISTS ix_user_roles_tenant ON user_roles (tenant_id);

-- -----------------------------------------------------------------------------
-- Meters
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS meters (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id       UUID NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,

    -- Optional external identifier from integration/utility provider.
    external_id     TEXT,

    name            TEXT NOT NULL,
    meter_type      TEXT NOT NULL DEFAULT 'electric' CHECK (meter_type IN ('electric', 'gas', 'water', 'steam', 'other')),
    unit            TEXT NOT NULL DEFAULT 'kwh',
    timezone        TEXT NOT NULL DEFAULT 'UTC',
    location        TEXT,
    metadata        JSONB NOT NULL DEFAULT '{}'::jsonb,

    status          TEXT NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'inactive')),
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT now(),

    CONSTRAINT chk_meters_name_nonempty CHECK (length(trim(name)) > 0)
);

CREATE INDEX IF NOT EXISTS ix_meters_tenant ON meters (tenant_id);
-- Unique per tenant where external_id is present.
CREATE UNIQUE INDEX IF NOT EXISTS ux_meters_tenant_external_id
    ON meters (tenant_id, external_id)
    WHERE external_id IS NOT NULL;

-- Search support for metadata
CREATE INDEX IF NOT EXISTS ix_meters_metadata_gin ON meters USING GIN (metadata);

DROP TRIGGER IF EXISTS trg_meters_set_updated_at ON meters;
CREATE TRIGGER trg_meters_set_updated_at
BEFORE UPDATE ON meters
FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- -----------------------------------------------------------------------------
-- Meter readings (time-series)
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS meter_readings (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id       UUID NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
    meter_id        UUID NOT NULL REFERENCES meters(id) ON DELETE CASCADE,

    reading_at      TIMESTAMPTZ NOT NULL,

    -- Numeric chosen for precision in energy/billing contexts.
    value           NUMERIC(18, 6) NOT NULL,

    quality         TEXT NOT NULL DEFAULT 'actual' CHECK (quality IN ('actual', 'estimated', 'missing', 'corrected')),
    source          TEXT NOT NULL DEFAULT 'upload' CHECK (source IN ('upload', 'api', 'integration', 'system')),
    metadata        JSONB NOT NULL DEFAULT '{}'::jsonb,

    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),

    CONSTRAINT chk_meter_readings_value_nonnegative CHECK (value >= 0)
);

-- Prevent duplicate readings at a timestamp per meter (common ingestion constraint).
CREATE UNIQUE INDEX IF NOT EXISTS ux_meter_readings_meter_time ON meter_readings (meter_id, reading_at);
-- Tenant+time supports dashboards and analytics scans.
CREATE INDEX IF NOT EXISTS ix_meter_readings_tenant_time ON meter_readings (tenant_id, reading_at DESC);
CREATE INDEX IF NOT EXISTS ix_meter_readings_meter_time_desc ON meter_readings (meter_id, reading_at DESC);
CREATE INDEX IF NOT EXISTS ix_meter_readings_metadata_gin ON meter_readings USING GIN (metadata);

-- -----------------------------------------------------------------------------
-- Documents (uploads and extracted artifacts)
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS documents (
    id                  UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id           UUID NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
    uploaded_by_user_id UUID REFERENCES users(id) ON DELETE SET NULL,

    filename            TEXT NOT NULL,
    content_type        TEXT,

    -- Storage is abstracted (S3 key, local path, blob reference).
    storage_key         TEXT NOT NULL,
    file_size_bytes     BIGINT,
    sha256              TEXT,

    document_type       TEXT NOT NULL DEFAULT 'unknown' CHECK (document_type IN ('invoice', 'statement', 'contract', 'other', 'unknown')),
    status              TEXT NOT NULL DEFAULT 'uploaded' CHECK (status IN ('uploaded', 'processing', 'processed', 'failed', 'deleted')),

    -- Extracted text / structured data
    extracted_text      TEXT,
    extracted_data      JSONB NOT NULL DEFAULT '{}'::jsonb,

    tags                TEXT[] NOT NULL DEFAULT ARRAY[]::TEXT[],

    created_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
    deleted_at          TIMESTAMPTZ,

    CONSTRAINT chk_documents_filename_nonempty CHECK (length(trim(filename)) > 0),
    CONSTRAINT chk_documents_storage_key_nonempty CHECK (length(trim(storage_key)) > 0),
    CONSTRAINT chk_documents_file_size_nonnegative CHECK (file_size_bytes IS NULL OR file_size_bytes >= 0)
);

-- For list views and filtering
CREATE INDEX IF NOT EXISTS ix_documents_tenant_created ON documents (tenant_id, created_at DESC);
CREATE INDEX IF NOT EXISTS ix_documents_tenant_status_created ON documents (tenant_id, status, created_at DESC);
CREATE INDEX IF NOT EXISTS ix_documents_uploaded_by ON documents (uploaded_by_user_id);
CREATE INDEX IF NOT EXISTS ix_documents_status ON documents (status);
CREATE INDEX IF NOT EXISTS ix_documents_deleted_at ON documents (deleted_at);

-- Tag and extracted data search
CREATE INDEX IF NOT EXISTS ix_documents_tags_gin ON documents USING GIN (tags);
CREATE INDEX IF NOT EXISTS ix_documents_extracted_data_gin ON documents USING GIN (extracted_data);

-- If sha256 is captured, prevent duplicates within a tenant (optional but useful).
CREATE UNIQUE INDEX IF NOT EXISTS ux_documents_tenant_sha256
    ON documents (tenant_id, sha256)
    WHERE sha256 IS NOT NULL;

DROP TRIGGER IF EXISTS trg_documents_set_updated_at ON documents;
CREATE TRIGGER trg_documents_set_updated_at
BEFORE UPDATE ON documents
FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- -----------------------------------------------------------------------------
-- Analytics outputs (aggregations, model outputs, benchmarks)
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS analytics_outputs (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id       UUID NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,

    -- Optional links depending on what generated the output
    meter_id        UUID REFERENCES meters(id) ON DELETE SET NULL,
    document_id     UUID REFERENCES documents(id) ON DELETE SET NULL,

    output_type     TEXT NOT NULL,
    granularity     TEXT,
    window_start    TIMESTAMPTZ,
    window_end      TIMESTAMPTZ,

    model_version   TEXT,

    output          JSONB NOT NULL,
    score           NUMERIC(18, 6),

    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),

    CONSTRAINT chk_analytics_outputs_type_nonempty CHECK (length(trim(output_type)) > 0),
    CONSTRAINT chk_analytics_outputs_window_order CHECK (
        window_start IS NULL OR window_end IS NULL OR window_end >= window_start
    )
);

-- Query patterns: recent outputs, by type, by meter
CREATE INDEX IF NOT EXISTS ix_analytics_outputs_tenant_created ON analytics_outputs (tenant_id, created_at DESC);
CREATE INDEX IF NOT EXISTS ix_analytics_outputs_meter_created ON analytics_outputs (meter_id, created_at DESC);
CREATE INDEX IF NOT EXISTS ix_analytics_outputs_document_created ON analytics_outputs (document_id, created_at DESC);
CREATE INDEX IF NOT EXISTS ix_analytics_outputs_tenant_type_created ON analytics_outputs (tenant_id, output_type, created_at DESC);
CREATE INDEX IF NOT EXISTS ix_analytics_outputs_output_gin ON analytics_outputs USING GIN (output);

-- -----------------------------------------------------------------------------
-- Alerts / notifications
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS alerts (
    id                  UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id           UUID NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,

    -- Recipient and related entities (optional)
    user_id             UUID REFERENCES users(id) ON DELETE SET NULL,
    meter_id            UUID REFERENCES meters(id) ON DELETE SET NULL,
    analytics_output_id UUID REFERENCES analytics_outputs(id) ON DELETE SET NULL,

    severity            TEXT NOT NULL DEFAULT 'info' CHECK (severity IN ('info', 'warning', 'critical')),
    title               TEXT NOT NULL,
    message             TEXT NOT NULL,

    status              TEXT NOT NULL DEFAULT 'open' CHECK (status IN ('open', 'acknowledged', 'resolved', 'dismissed')),

    -- Delivery channels can be expanded: email, sms, webhook, push, etc.
    channel             TEXT NOT NULL DEFAULT 'in_app' CHECK (channel IN ('in_app', 'email', 'sms', 'webhook')),

    delivered_at        TIMESTAMPTZ,
    read_at             TIMESTAMPTZ,

    created_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at          TIMESTAMPTZ NOT NULL DEFAULT now(),

    CONSTRAINT chk_alerts_title_nonempty CHECK (length(trim(title)) > 0),
    CONSTRAINT chk_alerts_message_nonempty CHECK (length(trim(message)) > 0)
);

-- Common alert center queries
CREATE INDEX IF NOT EXISTS ix_alerts_tenant_created ON alerts (tenant_id, created_at DESC);
CREATE INDEX IF NOT EXISTS ix_alerts_tenant_status_created ON alerts (tenant_id, status, created_at DESC);
CREATE INDEX IF NOT EXISTS ix_alerts_user_status_created ON alerts (user_id, status, created_at DESC);
CREATE INDEX IF NOT EXISTS ix_alerts_meter_created ON alerts (meter_id, created_at DESC);
CREATE INDEX IF NOT EXISTS ix_alerts_severity ON alerts (tenant_id, severity, created_at DESC);

DROP TRIGGER IF EXISTS trg_alerts_set_updated_at ON alerts;
CREATE TRIGGER trg_alerts_set_updated_at
BEFORE UPDATE ON alerts
FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- -----------------------------------------------------------------------------
-- Audit logs (security/compliance/troubleshooting)
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS audit_logs (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id       UUID NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,

    actor_user_id   UUID REFERENCES users(id) ON DELETE SET NULL,

    action          TEXT NOT NULL,
    entity_type     TEXT,
    entity_id       UUID,

    ip_address      INET,
    user_agent      TEXT,

    details         JSONB NOT NULL DEFAULT '{}'::jsonb,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),

    CONSTRAINT chk_audit_logs_action_nonempty CHECK (length(trim(action)) > 0)
);

CREATE INDEX IF NOT EXISTS ix_audit_logs_tenant_created ON audit_logs (tenant_id, created_at DESC);
CREATE INDEX IF NOT EXISTS ix_audit_logs_actor_created ON audit_logs (actor_user_id, created_at DESC);
CREATE INDEX IF NOT EXISTS ix_audit_logs_tenant_action_created ON audit_logs (tenant_id, action, created_at DESC);
CREATE INDEX IF NOT EXISTS ix_audit_logs_entity ON audit_logs (tenant_id, entity_type, entity_id, created_at DESC);
CREATE INDEX IF NOT EXISTS ix_audit_logs_details_gin ON audit_logs USING GIN (details);

COMMIT;
