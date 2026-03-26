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
   - Ideally idempotent when feasible (`IF NOT EXISTS`, etc.)
3. Apply:
   ```bash
   ./migrate.sh
   ```

## Initial schema
The initial schema is defined in:
- `database/migrations/001_init_schema.sql`

It includes the core tables:
- tenants
- users / roles / user_roles
- meters
- meter_readings
- documents
- analytics_outputs
- alerts
- audit_logs

With constraints and indexes appropriate for a multi-tenant SaaS.
