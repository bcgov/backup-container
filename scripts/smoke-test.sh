#!/usr/bin/env bash
# Smoke test for the local backup workflow.
#
# This script validates the end-to-end backup path used by the project:
#   1. ensure a source database exists
#   2. load Sakila sample data if it is missing
#   3. create a backup archive
#   4. restore the newest backup into a second database
#   5. compare each restored table against the source data
#
# The comparison is intentionally done against the actual table rows, exported as CSV,
# rather than comparing raw pg_dump output. Raw dump text contains PostgreSQL metadata
# that can differ between environments even when the data is identical.
#
# Usage:
#   bash scripts/smoke-test.sh
#
# Environment overrides:
#   COMPOSE_CMD    default: docker compose
#   RETRY_COUNT    default: 30
#   SLEEP_SECONDS  default: 2
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT_DIR}"

COMPOSE_CMD="${COMPOSE_CMD:-docker compose}"
RETRY_COUNT="${RETRY_COUNT:-30}"
SLEEP_SECONDS="${SLEEP_SECONDS:-2}"
DB_NAME="sakila"
RESTORE_DB_NAME="sakila_restore"

# Run a docker compose subcommand. This keeps the script portable across
# environments where the user sets COMPOSE_CMD to a custom command.
run_compose() {
  if [[ -n "${COMPOSE_CMD:-}" ]]; then
    local -a compose_cmd
    read -r -a compose_cmd <<< "${COMPOSE_CMD}"
    "${compose_cmd[@]}" "$@"
  else
    docker compose "$@"
  fi
}

# Run a psql statement against the given database in the PostgreSQL container.
run_psql() {
  local db_name="${1:-postgres}"
  shift

  run_compose exec -T postgresql psql -U postgres -d "${db_name}" "$@"
}

# Execute a single SQL query and return the raw output from psql.
run_sql_query() {
  local db_name="${1:-postgres}"
  local sql="${2}"

  run_psql "${db_name}" -tAc "${sql}"
}

# Export an ordered table snapshot as CSV so it can be diffed against the restored DB.
export_table_csv() {
  local db_name="${1}"
  local table_name="${2}"
  local order_by="${3}"
  local output_file="${4}"

  run_psql "${db_name}" -q -A -t -c "COPY (SELECT * FROM \"${table_name}\" ${order_by}) TO STDOUT WITH CSV" > "${output_file}"
}

# Wait until the PostgreSQL container will accept connections.
wait_for_postgres() {
  local attempt

  for attempt in $(seq 1 "${RETRY_COUNT}"); do
    if run_compose exec -T postgresql pg_isready -U postgres >/dev/null 2>&1; then
      return 0
    fi

    echo "Waiting for PostgreSQL to become ready (${attempt}/${RETRY_COUNT})..."
    sleep "${SLEEP_SECONDS}"
  done

  echo "PostgreSQL did not become ready in time." >&2
  return 1
}

# Create a database if it does not already exist.
ensure_database_exists() {
  local db_name="$1"
  local exists

  exists=$(run_sql_query postgres "SELECT 1 FROM pg_database WHERE datname='${db_name}';")

  if [[ "${exists}" != "1" ]]; then
    echo "Creating ${db_name} database..."
    run_compose exec -T postgresql psql -U postgres -d postgres -c "CREATE DATABASE \"${db_name}\";"
  fi
}

# Ensure the Sakila sample database is populated for a realistic smoke-test payload.
ensure_sakila_data() {
  local table_count

  table_count=$(run_sql_query "${DB_NAME}" "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='public' AND table_name='actor';")

  if [[ "${table_count}" == "0" ]]; then
    echo "Loading Sakila schema..."
    curl -fsSL https://raw.githubusercontent.com/jOOQ/sakila/main/postgres-sakila-db/postgres-sakila-schema.sql \
      | run_compose exec -T -i postgresql psql -U postgres -d "${DB_NAME}"

    echo "Loading Sakila data..."
    curl -fsSL https://raw.githubusercontent.com/jOOQ/sakila/main/postgres-sakila-db/postgres-sakila-insert-data.sql \
      | run_compose exec -T -i postgresql psql -U postgres -d "${DB_NAME}"
  fi
}

# Locate the newest backup archive in the mounted backup directory.
latest_backup_file() {
  run_compose exec -T backup bash -lc '
    find /backups -type f -name "*.sql.gz" \
      -printf "%TY-%Tm-%Td %TH:%TM:%TS %p\n" \
      | sort \
      | tail -n 1 \
      | sed "s~^.* \(.*$\)~\1~"'
}

# Restore the newest backup archive into a second validation database.
restore_latest_backup() {
  local backup_file

  backup_file="$(latest_backup_file)"

  if [[ -z "${backup_file}" ]]; then
    echo "No backup file found to restore." >&2
    return 1
  fi

  ensure_database_exists "${RESTORE_DB_NAME}"

  echo "Restoring ${backup_file} into ${RESTORE_DB_NAME}..."
  # Run the restore in scripted mode so it does not block waiting for a keypress.
  # The backup utility treats SCHEDULED_RUN as a non-interactive execution mode,
  # which keeps this smoke test fully unattended.
  run_compose exec -T backup env SCHEDULED_RUN=1 /backup.sh \
    -r "postgresql:5432/${RESTORE_DB_NAME}" \
    -a secret \
    -f "${backup_file}"
}

# Get every public base table from the source database so each table can be validated.
get_table_names() {
  run_sql_query "${DB_NAME}" "SELECT table_name FROM information_schema.tables WHERE table_schema='public' AND table_type='BASE TABLE' ORDER BY table_name;"
}

# Determine the first primary key column for a table so the export order is stable.
get_primary_key_column() {
  local table_name="${1}"

  run_sql_query "${DB_NAME}" "SELECT column_name FROM information_schema.columns WHERE table_schema='public' AND table_name='${table_name}' AND column_name IN (SELECT column_name FROM information_schema.key_column_usage WHERE table_schema='public' AND table_name='${table_name}' AND constraint_name IN (SELECT constraint_name FROM information_schema.table_constraints WHERE table_schema='public' AND table_name='${table_name}' AND constraint_type='PRIMARY KEY')) ORDER BY ordinal_position LIMIT 1;"
}

# Compare source and restored data by exporting each table to CSV and diffing it.
compare_database_data() {
  local table
  local tables
  local source_csv
  local restore_csv
  local order_by
  local first_pk

  tables=$(get_table_names)

  for table in ${tables}; do
    source_csv=$(mktemp)
    restore_csv=$(mktemp)
    first_pk=$(get_primary_key_column "${table}")

    if [[ -n "${first_pk}" ]]; then
      order_by="ORDER BY \"${first_pk}\""
    else
      order_by=""
    fi

    echo "Comparing table ${table}..."
    export_table_csv "${DB_NAME}" "${table}" "${order_by}" "${source_csv}"
    export_table_csv "${RESTORE_DB_NAME}" "${table}" "${order_by}" "${restore_csv}"

    if ! diff -u "${source_csv}" "${restore_csv}"; then
      echo "Data mismatch detected for table: ${table}" >&2
      rm -f "${source_csv}" "${restore_csv}"
      return 1
    fi

    rm -f "${source_csv}" "${restore_csv}"
  done

  echo "All restored tables match the original source data."
}

# Run the backup command, then restore and validate the newest archive.
run_backup_smoke_test() {
  echo "Running backup.sh -1..."
  run_compose exec -T backup /backup.sh -1 > /tmp/backup-container-smoke.log 2>&1

  echo "Latest backup files:"
  run_compose exec -T backup bash -lc '
    find /backups -type f -name "*.sql.gz" \
      -printf "%TY-%Tm-%Td %TH:%TM:%TS %p\n" \
      | sort \
      | tail -n 5'

  restore_latest_backup
  compare_database_data
}

# Entry point for the smoke test.
main() {
  if ! run_compose ps >/dev/null 2>&1; then
    echo "Compose stack is not running. Run: docker compose up -d first."
    exit 1
  fi

  wait_for_postgres
  ensure_database_exists "${DB_NAME}"
  ensure_sakila_data
  run_backup_smoke_test

  echo "Smoke test passed."
}

main "$@"
