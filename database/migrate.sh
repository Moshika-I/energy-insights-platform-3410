#!/bin/bash
set -euo pipefail

# Simple SQL-file-based migration runner for the PostgreSQL container.
# - Uses db_connection.txt as the authoritative connection string.
# - Tracks applied migrations in schema_migrations.
#
# Usage:
#   ./migrate.sh
#
# Notes:
# - Runs migrations in lexical order (e.g., 001_*, 002_*).
# - Each migration file should be idempotent where possible.
# - This script intentionally avoids external migration tooling.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DB_DIR="${SCRIPT_DIR}"
MIGRATIONS_DIR="${DB_DIR}/migrations"
CONN_FILE="${DB_DIR}/db_connection.txt"

if [ ! -f "${CONN_FILE}" ]; then
  echo "ERROR: ${CONN_FILE} not found. Run startup.sh first to initialize and create connection string."
  exit 1
fi

# db_connection.txt contains a full psql command like:
#   psql postgresql://user:pass@localhost:5000/mydb
PSQL_CMD="$(cat "${CONN_FILE}")"

if [ -z "${PSQL_CMD}" ]; then
  echo "ERROR: ${CONN_FILE} is empty."
  exit 1
fi

if [ ! -d "${MIGRATIONS_DIR}" ]; then
  echo "No migrations directory found at ${MIGRATIONS_DIR}. Nothing to do."
  exit 0
fi

echo "Running migrations using: ${PSQL_CMD}"

# Ensure schema_migrations table exists (separate from any migration file so we can track safely)
${PSQL_CMD} -v ON_ERROR_STOP=1 -c "CREATE TABLE IF NOT EXISTS schema_migrations (version TEXT PRIMARY KEY, applied_at TIMESTAMPTZ NOT NULL DEFAULT now());"

shopt -s nullglob
MIGRATION_FILES=("${MIGRATIONS_DIR}"/*.sql)

if [ ${#MIGRATION_FILES[@]} -eq 0 ]; then
  echo "No migration files found in ${MIGRATIONS_DIR}. Nothing to do."
  exit 0
fi

for file in "${MIGRATION_FILES[@]}"; do
  base="$(basename "${file}")"
  version="${base%.sql}"

  # Check if applied
  APPLIED="$(${PSQL_CMD} -t -A -c "SELECT 1 FROM schema_migrations WHERE version='${version}' LIMIT 1;" || true)"

  if [ "${APPLIED}" = "1" ]; then
    echo "✓ Skipping already applied migration: ${version}"
    continue
  fi

  echo "→ Applying migration: ${version}"
  ${PSQL_CMD} -v ON_ERROR_STOP=1 -f "${file}"

  # Record migration version
  ${PSQL_CMD} -v ON_ERROR_STOP=1 -c "INSERT INTO schema_migrations(version) VALUES ('${version}');"
  echo "✓ Applied: ${version}"
done

echo "All migrations are up to date."
