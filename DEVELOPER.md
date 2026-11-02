## Docker

This project contains a docker-compose.yml file suitable for development purposes. It will start a PostgreSQL database, MinIO-compatible S3 storage, and a backup container.

Note: the legacy `minio/minio` Docker Hub image has been removed. This repo uses the maintained `quay.io/minio/aistor/minio:latest` image so local development continues to work without a Docker Hub login.

Because all the bash scripts are mounted to root `/`, the docker-compose file mounts them individually. If you wish to add new files, create them and then add them to the backup container mounts. This method allows you to edit the files on the host and have changes immediately available in the container. You may need to restart the backup process to see the changes.

To start the containers run:

```bash
docker compose up -d --build
```

Once all 3 containers start they will create three folders that are **not** tracked by git:

- `./pg-data` - PostgreSQL database
- `./minio-data` - MinIO storage
- `./backups` - backup archives

NOTE: MinIO needs at least 1G of free space to function properly. Make sure you have some free local space.

Add this shell (bash or zsh) alias to quickly connect to a container by name:

```bash
dcon='function _dcon(){ docker exec -i -t $1 /bin/bash -c "export COLUMNS=`tput cols`; export LINES=`tput lines`; exec bash"; };_dcon'
```

Use `docker ps` to list all running containers and then use `dcon <container_name>` to connect to the container.

```bash
dcon backup-container-postgresql-1
```

### Protips 🤓

- Newer Docker releases do not require the hyphen. `docker compose` is preferred over `docker-compose`.
- This bash one-liner was used to add all the files to the backup container volumes:

```bash
ls docker/ | grep 'backup\.' | awk '{ print "- ./docker/"$1":/"$1 }'
```

## Smoke test

The project includes a smoke test that validates a real backup/restore flow.

What it does:

1. Ensures the source database exists.
2. Loads a Sakila schema/data set if it is not already present.
3. Runs the backup command to produce a `.sql.gz` archive.
4. Locates the newest backup.
5. Restores that backup into a second database (`sakila_restore`).
6. Exports each table from both databases to CSV with a stable row ordering.
7. Compares the CSV output and exits non-zero on any mismatch.

This is the working validation strategy for the smoke test: compare the actual table data from the source and restored databases rather than comparing raw `pg_dump` output, which includes version-specific metadata and can differ even when the underlying data matches.

Run the smoke test after the stack is up:

```bash
docker compose up -d --build
bash scripts/smoke-test.sh
```

The script prints progress as it creates the database, loads Sakila data, runs the backup, restores the archive, and compares the table contents. If it passes, the final output includes:

```text
All restored tables match the original source data.
Smoke test passed.
```

On a typical local development machine, the smoke test completes in roughly 20-30 seconds once the Docker stack is already running.

## Postgres

Connect to the postgres container using the `dcon` alias noted above and create the database, schema, and sample data.

Connect to the postgres container:

```bash
dcon backup-container-postgresql-1
```

Run the `psql` command to connect to the database and create the database:

```bash
psql -U postgres
create database sakila;
^D
```

Run the following two commands to create the schema and insert the data. If `curl` is not installed, run `apt-get update && apt-get install curl` first.

```bash
curl -sSL https://raw.githubusercontent.com/jOOQ/sakila/main/postgres-sakila-db/postgres-sakila-schema.sql | psql -U postgres -d sakila;
```

```bash
curl -sSL https://raw.githubusercontent.com/jOOQ/sakila/main/postgres-sakila-db/postgres-sakila-insert-data.sql | psql -U postgres -d sakila;
```

You should now have a sample database with data.
