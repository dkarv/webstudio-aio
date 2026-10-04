#!/usr/bin/env bash
# Initializes /data (database, secrets) and then hands over to supervisord.
set -euo pipefail

log() { echo "[entrypoint] $*"; }

DATA=/data
PGDATA="$DATA/postgres"
SECRETS="$DATA/secrets"

mkdir -p "$PGDATA" "$SECRETS" "$DATA/assets" "$DATA/backup"
chown postgres:postgres "$DATA/backup"
chmod 700 "$SECRETS"
chown postgres:postgres "$PGDATA"
chmod 700 "$PGDATA"
chown node:node "$DATA/assets"

# Read a value from the environment, or from a secret generated once and persisted in /data.
secret() {
  local name="$1" file="$SECRETS/$1"
  if [ -n "${!name:-}" ]; then
    echo "${!name}"
  elif [ -f "$file" ]; then
    cat "$file"
  else
    openssl rand -hex 24 | tee "$file"
  fi
}

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
: "${WEBSTUDIO_HOST:=webstudio.localhost}"
# The builder listens on this port directly. It must equal the published port
# ("-p 8080:8080" with PORT=8080), because the builder calls its own public
# origin server-side during login.
: "${PORT:=80}"
# true when a reverse proxy in front terminates https for <host> and *.<host>.
# PORT is then only the internal port the proxy forwards to.
: "${BEHIND_PROXY:=false}"
export BEHIND_PROXY

DB_NAME=webstudio
DB_USER=webstudio
DB_PASSWORD="$(secret POSTGRES_PASSWORD)"

export AUTH_SECRET="$(secret AUTH_SECRET)"
export AUTH_WS_CLIENT_ID="$(secret AUTH_WS_CLIENT_ID)"
export AUTH_WS_CLIENT_SECRET="$(secret AUTH_WS_CLIENT_SECRET)"
export TRPC_SERVER_API_TOKEN="$(secret TRPC_SERVER_API_TOKEN)"

export DATABASE_URL="postgresql://$DB_USER:$DB_PASSWORD@127.0.0.1:5432/$DB_NAME"
export DIRECT_URL="$DATABASE_URL"

export PGRST_DB_URI="$DATABASE_URL"
export PGRST_DB_SCHEMAS=public
export PGRST_DB_ANON_ROLE="$DB_USER"
export PGRST_SERVER_HOST=127.0.0.1
export PGRST_SERVER_PORT=3001
export POSTGREST_URL="http://127.0.0.1:3001"
export POSTGREST_API_KEY=""

export HOST=0.0.0.0
export PORT

# Without OAuth credentials, login works with any email + AUTH_SECRET.
export DEV_LOGIN="${DEV_LOGIN:-true}"
export FEATURE_FLAGS="${FEATURE_FLAGS:-}"
# A self-hosted instance should not be limited by the free plan. Users pick the plan on login.
DEFAULT_PLANS='[{"name":"Pro","features":{"canDownloadAssets":true,"canRestoreBackups":true,"allowAdditionalPermissions":true,"allowDynamicData":true,"allowAuth":true,"allowContentMode":true,"allowStagingPublish":true,"maxContactEmailsPerProject":5,"maxDomainsAllowedPerUser":200,"maxDailyPublishesPerUser":100,"maxProjectsAllowedPerUser":1000,"maxAssetsPerProject":1000,"maxWorkspaces":20,"seatsIncluded":20,"maxSeatsPerWorkspace":50}}]'
export PLANS="${PLANS:-$DEFAULT_PLANS}"

# ---------------------------------------------------------------------------
# Database: init, bootstrap roles/extensions, run migrations
# ---------------------------------------------------------------------------
as_pg() { setpriv --reuid=postgres --regid=postgres --init-groups "$@"; }

if [ ! -s "$PGDATA/PG_VERSION" ]; then
  log "Initializing PostgreSQL cluster"
  pwfile="$(mktemp)"
  echo "$DB_PASSWORD" >"$pwfile"
  chown postgres "$pwfile"
  as_pg initdb -D "$PGDATA" -U postgres --encoding=UTF8 --locale=C.UTF-8 \
    --auth-local=peer --auth-host=scram-sha-256 >/dev/null
  rm -f "$pwfile"
fi

log "Starting PostgreSQL for bootstrap and migrations"
as_pg pg_ctl -D "$PGDATA" -w -t 60 -o "-c listen_addresses=127.0.0.1 -c port=5432" start >/dev/null

as_pg psql -q -v ON_ERROR_STOP=1 -d postgres \
  -v user="$DB_USER" -v pass="$DB_PASSWORD" -v db="$DB_NAME" <<'SQL'
SELECT format('CREATE ROLE %I SUPERUSER LOGIN', :'user')
  WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = :'user') \gexec
ALTER ROLE :"user" WITH PASSWORD :'pass';
SELECT format('CREATE DATABASE %I OWNER %I', :'db', :'user')
  WHERE NOT EXISTS (SELECT 1 FROM pg_database WHERE datname = :'db') \gexec
SQL

# Mirrors apps/builder/backend/postgres/init.sql from upstream.
as_pg psql -q -v ON_ERROR_STOP=1 -d "$DB_NAME" -v user="$DB_USER" <<'SQL'
CREATE SCHEMA IF NOT EXISTS extensions;
CREATE EXTENSION IF NOT EXISTS "uuid-ossp" WITH SCHEMA extensions;
ALTER ROLE :"user" SET search_path TO public, extensions;
SQL

log "Running Webstudio database migrations"
(
  cd /app/packages/prisma-client
  setpriv --reuid=node --regid=node --init-groups env HOME=/home/node \
    PATH="/app/packages/prisma-client/node_modules/.bin:/app/node_modules/.bin:$PATH" \
    tsx migrations-cli/cli.ts migrate --cwd ../../apps/builder
) || {
  as_pg pg_ctl -D "$PGDATA" -m fast stop >/dev/null
  exit 1
}

as_pg pg_ctl -D "$PGDATA" -m fast -w stop >/dev/null

# The builder opens every project on its own subdomain (p-<projectId>.<host>)
# and exchanges an OAuth code by calling its own public origin from the server.
if [ "$BEHIND_PROXY" = "true" ]; then
  # The proxy must be reachable as <host> from inside this container.
  log "Webstudio will be available at https://$WEBSTUDIO_HOST (behind proxy, port $PORT)"
else
  # Plain http: <host> has to resolve to this container.
  if ! grep -qE "[[:space:]]$WEBSTUDIO_HOST([[:space:]]|\$)" /etc/hosts; then
    echo "127.0.0.1 $WEBSTUDIO_HOST" >>/etc/hosts
  fi
  log "Webstudio will be available at http://$WEBSTUDIO_HOST$([ "$PORT" = 80 ] || echo ":$PORT")"
fi
if [ "$DEV_LOGIN" = "true" ]; then
  log "Login secret (AUTH_SECRET): $AUTH_SECRET"
fi

exec "$@"
