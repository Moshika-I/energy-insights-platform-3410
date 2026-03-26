-- Energy Insights Platform - Initial PostgreSQL Schema
-- Migration: 001_init_schema
--
-- Notes:
-- - Uses UUID primary keys via pgcrypto's gen_random_uuid().
-- - Uses JSONB for flexible metadata where appropriate.
-- - Uses soft-delete fields (deleted_at) on selected entities where useful.
-- - Multi-tenant: most domain tables include tenant_id with indexes.
--
-- This file is applied by database/migrate.sh and tracked in schema_migrations.

BEGIN;

-- Extensions (idempotent)
CREATE EXTENSION IF NOT EXISTS pgcrypto;

-- -----------------------------------------------------------------------------
-- Schema migrations tracking
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS schema_migrations (
    version         TEXT PRIMARY KEY,
    applied_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);

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

CREATE UNIQUE INDEX IF NOT EXISTS ux_tenants_slug ON tenants (slug);

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
    last_login_at   TIMESTAMPTZ
);

-- Enforce email uniqueness per tenant.
CREATE UNIQUE INDEX IF NOT EXISTS ux_users_tenant_email ON users (tenant_id, lower(email));
CREATE INDEX IF NOT EXISTS ix_users_tenant ON users (tenant_id);
CREATE INDEX IF NOT EXISTS ix_users_auth_subject ON users (auth_subject);

CREATE TABLE IF NOT EXISTS roles (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    name            TEXT NOT NULL,
    description     TEXT,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE UNIQUE INDEX IF NOT EXISTS ux_roles_name ON roles (name);

CREATE TABLE IF NOT EXISTS user_roles (
    tenant_id       UUID NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
    user_id         UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    role_id         UUID NOT NULL REFERENCES roles(id) ON DELETE CASCADE,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (tenant_id, user_id, role_id)
);

CREATE INDEX IF NOT EXISTS ix_user_roles_user ON user_roles (user_id);
CREATE INDEX IF NOT EXISTS ix_user_roles_role ON user_roles (role_id);

-- -----------------------------------------------------------------------------
-- Meters and readings
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS meters (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id       UUID NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
    external_id     TEXT,
    name            TEXT NOT NULL,
    meter_type      TEXT NOT NULL DEFAULT 'electric' CHECK (meter_type IN ('electric', 'gas', 'water', 'steam', 'other')),
    unit            TEXT NOT NULL DEFAULT 'kwh',
    timezone        TEXT NOT NULL DEFAULT 'UTC',
    location        TEXT,
    metadata        JSONB NOT NULL DEFAULT '{}'::jsonb,
    status          TEXT NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'inactive')),
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS ix_meters_tenant ON meters (tenant_id);
CREATE UNIQUE INDEX IF NOT EXISTS ux_meters_tenant_external_id ON meters (tenant_id, external_id) WHERE external_id IS NOT NULL;

-- Readings: time-series consumption values
CREATE TABLE IF NOT EXISTS meter_readings (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id       UUID NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
    meter_id        UUID NOT NULL REFERENCES meters(id) ON DELETE CASCADE,
    reading_at      TIMESTAMPTZ NOT NULL,
    -- Numeric chosen over double precision for precision in energy billing contexts
    value           NUMERIC(18, 6) NOT NULL,
    quality         TEXT NOT NULL DEFAULT 'actual' CHECK (quality IN ('actual', 'estimated', 'missing', 'corrected')),
    source          TEXT NOT NULL DEFAULT 'upload' CHECK (source IN ('upload', 'api', 'integration', 'system')),
    metadata        JSONB NOT NULL DEFAULT '{}'::jsonb,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Prevent duplicate readings at a timestamp per meter (common ingestion constraint)
CREATE UNIQUE INDEX IF NOT EXISTS ux_meter_readings_meter_time ON meter_readings (meter_id, reading_at);
CREATE INDEX IF NOT EXISTS ix_meter_readings_tenant_time ON meter_readings (tenant_id, reading_at DESC);
CREATE INDEX IF NOT EXISTS ix_meter_readings_meter_time_desc ON meter_readings (meter_id, reading_at DESC);

-- -----------------------------------------------------------------------------
-- Documents (uploads, parsed/processed artifacts)
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS documents (
    id                  UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id           UUID NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
    uploaded_by_user_id UUID REFERENCES users(id) ON DELETE SET NULL,
    -- Original filename and content type for user-facing display and security checks
    filename            TEXT NOT NULL,
    content_type        TEXT,
    -- Storage is abstracted (S3 key, local path, blob reference)
    storage_key         TEXT NOT NULL,
    file_size_bytes     BIGINT,
    sha256              TEXT,
    document_type       TEXT NOT NULL DEFAULT 'unknown' CHECK (document_type IN ('invoice', 'statement', 'contract', 'other', 'unknown')),
    status              TEXT NOT NULL DEFAULT 'uploaded' CHECK (status IN ('uploaded', 'processing', 'processed', 'failed', 'deleted')),
    -- Extracted text / structured data references can live here for now
    extracted_text      TEXT,
    extracted_data      JSONB NOT NULL DEFAULT '{}'::jsonb,
    tags                TEXT[] NOT NULL DEFAULT ARRAY[]::TEXT[],
    created_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
    deleted_at          TIMESTAMPTZ
);

CREATE INDEX IF NOT EXISTS ix_documents_tenant_created ON documents (tenant_id, created_at DESC);
CREATE INDEX IF NOT EXISTS ix_documents_status ON documents (status);
CREATE INDEX IF NOT EXISTS ix_documents_uploaded_by ON documents (uploaded_by_user_id);
CREATE INDEX IF NOT EXISTS ix_documents_tags_gin ON documents USING GIN (tags);
CREATE INDEX IF NOT EXISTS ix_documents_extracted_data_gin ON documents USING GIN (extracted_data);

-- -----------------------------------------------------------------------------
-- Analytics outputs (model results, benchmarks, aggregations)
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS analytics_outputs (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id       UUID NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
    meter_id        UUID REFERENCES meters(id) ON DELETE SET NULL,
    document_id     UUID REFERENCES documents(id) ON DELETE SET NULL,
    output_type     TEXT NOT NULL,
    -- Example: "daily", "weekly", "monthly", "event", etc.
    granularity     TEXT,
    window_start    TIMESTAMPTZ,
    window_end      TIMESTAMPTZ,
    -- Version of the algorithm/model that produced the output
    model_version   TEXT,
    -- Result payload
    output          JSONB NOT NULL,
    -- Score can be used for anomaly scores, confidence, etc.
    score           NUMERIC(18, 6),
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS ix_analytics_outputs_tenant_created ON analytics_outputs (tenant_id, created_at DESC);
CREATE INDEX IF NOT EXISTS ix_analytics_outputs_meter_created ON analytics_outputs (meter_id, created_at DESC);
CREATE INDEX IF NOT EXISTS ix_analytics_outputs_type ON analytics_outputs (tenant_id, output_type, created_at DESC);
CREATE INDEX IF NOT EXISTS ix_analytics_outputs_output_gin ON analytics_outputs USING GIN (output);

-- -----------------------------------------------------------------------------
-- Alerts / notifications (in-app + delivery tracking)
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS alerts (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id       UUID NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
    user_id         UUID REFERENCES users(id) ON DELETE SET NULL,
    meter_id        UUID REFERENCES meters(id) ON DELETE SET NULL,
    analytics_output_id UUID REFERENCES analytics_outputs(id) ON DELETE SET NULL,
    severity        TEXT NOT NULL DEFAULT 'info' CHECK (severity IN ('info', 'warning', 'critical')),
    title           TEXT NOT NULL,
    message         TEXT NOT NULL,
    status          TEXT NOT NULL DEFAULT 'open' CHECK (status IN ('open', 'acknowledged', 'resolved', 'dismissed')),
    -- Delivery channels can be expanded: email, sms, webhook, push, etc.
    channel         TEXT NOT NULL DEFAULT 'in_app' CHECK (channel IN ('in_app', 'email', 'sms', 'webhook')),
    delivered_at    TIMESTAMPTZ,
    read_at         TIMESTAMPTZ,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS ix_alerts_tenant_created ON alerts (tenant_id, created_at DESC);
CREATE INDEX IF NOT EXISTS ix_alerts_user_status ON alerts (user_id, status, created_at DESC);
CREATE INDEX IF NOT EXISTS ix_alerts_meter_created ON alerts (meter_id, created_at DESC);
CREATE INDEX IF NOT EXISTS ix_alerts_status ON alerts (tenant_id, status, created_at DESC);

-- -----------------------------------------------------------------------------
-- Audit logs (security, compliance, troubleshooting)
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
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS ix_audit_logs_tenant_created ON audit_logs (tenant_id, created_at DESC);
CREATE INDEX IF NOT EXISTS ix_audit_logs_actor_created ON audit_logs (actor_user_id, created_at DESC);
CREATE INDEX IF NOT EXISTS ix_audit_logs_action ON audit_logs (tenant_id, action, created_at DESC);
CREATE INDEX IF NOT EXISTS ix_audit_logs_details_gin ON audit_logs USING GIN (details);

COMMIT;
