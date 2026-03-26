# Database migrations (PostgreSQL)

This container uses a minimal SQL-file-based migrations approach.

## Why this approach
- No external tools required (no Alembic/Flyway/etc.)
- Works with the existing `db_connection.txt` pattern in this repo
- Deterministic ordering via filename prefixes
- Tracks applied migrations in the `schema_migrations` table

## How it works
- `startup.sh` starts PostgreSQL and writes a `db_connection.txt` file containing a full `psql ...` command.
- `migrate.sh`:
  1. Reads `db_connection.txt` (authoritative connection)
  2. Ensures `schema_migrations` exists
  3. Applies all `database/migrations/*.sql` files in lexical order
  4. Records each applied migration by `version` (filename without `.sql`)

## Running migrations
From `energy-insights-platform-3410/database/`:

```bash
./startup.sh
./migrate.sh
```

## Adding a new migration
1. Create a new file under `database/migrations/`:
   - Use numeric prefixes: `002_add_xyz.sql`, `003_alter_abc.sql`, etc.
2. Keep migrations:
   - Safe to run once
   - Ideally idempotent where feasible (`IF NOT EXISTS`, `CREATE OR REPLACE`, etc.)
3. Apply:
   ```bash
   ./migrate.sh
   ```

## Initial schema (001_init_schema.sql)

The initial schema is defined in:
- `database/migrations/001_init_schema.sql`

It includes the core tables for a multi-tenant analytics SaaS:

### Tenancy
- `tenants`

### Users and roles
- `users` (scoped by `tenant_id`)
- `roles` (global)
- `user_roles` (tenant-scoped assignments)

### Metering
- `meters` (scoped by `tenant_id`)
- `meter_readings` (time-series readings; de-dup by `(meter_id, reading_at)`)

### Document management
- `documents` (uploads + extracted artifacts)

### Analytics
- `analytics_outputs` (model outputs/aggregations linked to meter/document where applicable)

### Alerts / notifications
- `alerts` (in-app notifications and delivery tracking)

### Audit logging
- `audit_logs` (security/compliance activity trail)

### Constraints and indexes
The schema includes:
- Case-insensitive uniqueness for tenant slug and tenant-scoped user emails
- Foreign key constraints with appropriate `ON DELETE` actions
- Check constraints for status/severity/type enums
- Indexes for common access patterns:
  - `tenant_id` + `created_at` for list views
  - `(meter_id, reading_at)` for time-series reads and ingestion de-dupe
  - GIN indexes for JSONB payloads and tags arrays

### Timestamps
- Most mutable tables include `updated_at`
- A shared trigger function `set_updated_at()` updates `updated_at` on UPDATE for:
  - tenants, users, meters, documents, alerts

If you need new tables/fields, add a new migration rather than editing `001_init_schema.sql` after it has been applied in an environment.
