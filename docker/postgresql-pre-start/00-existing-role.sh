#!/bin/bash

# This fix applies to PostgreSQL 14, 15, 16, and 18.
# Fixed-commit sources for the original create_users function in common.sh:
# PostgreSQL 14:
# https://github.com/sclorg/postgresql-container/blob/3c7bb2f43ae646c633ceb9e6c534582ec421ca42/14/root/usr/share/container-scripts/postgresql/common.sh#L242-L253
# PostgreSQL 15:
# https://github.com/sclorg/postgresql-container/blob/9264dbf56c67cb97beeda8704e9882e69305d75f/15/root/usr/share/container-scripts/postgresql/common.sh#L226-L237
# PostgreSQL 16:
# https://github.com/sclorg/postgresql-container/blob/9264dbf56c67cb97beeda8704e9882e69305d75f/16/root/usr/share/container-scripts/postgresql/common.sh#L226-L237
# PostgreSQL 18:
# https://github.com/sclorg/postgresql-container/blob/9264dbf56c67cb97beeda8704e9882e69305d75f/18/root/usr/share/container-scripts/postgresql/common.sh#L226-L237
# This pre-start hook redefines create_users after common.sh is loaded.
function create_users() {
    if [[ ",$postinitdb_actions," = *,simple_db,* ]]; then
        # Added check: initdb already creates postgres. Upstream's unconditional
        # createuser fails when POSTGRESQL_USER=postgres: role already exists.
        local role_exists
        role_exists=$(
            psql -X -A -t --dbname=postgres --set=ON_ERROR_STOP=1 \
                --set=role_name="$POSTGRESQL_USER" <<'SQL'
SELECT EXISTS (
    SELECT 1 FROM pg_catalog.pg_roles WHERE rolname = :'role_name'
);
SQL
        ) || return $?

        case "$role_exists" in
            t)
                # Skip only role creation; still create the database below.
                echo "Verification role \"$POSTGRESQL_USER\" already exists; skipping creation."
                ;;
            f)
                # Preserve upstream behavior when the requested role is missing.
                createuser -- "$POSTGRESQL_USER" || return $?
                ;;
            *)
                # Fail startup rather than continue with an unexpected lookup result.
                echo "Unexpected role lookup result: $role_exists" >&2
                return 1
                ;;
        esac
        createdb --owner="$POSTGRESQL_USER" "$POSTGRESQL_DATABASE" || return $?
    fi

    if [ -v POSTGRESQL_MASTER_USER ]; then
        createuser "$POSTGRESQL_MASTER_USER" || return $?
        echo "ALTER DATABASE postgres OWNER TO $POSTGRESQL_MASTER_USER;" | psql
        echo "GRANT ALL PRIVILEGES on DATABASE postgres TO $POSTGRESQL_MASTER_USER;" | psql
    fi
}