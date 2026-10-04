# syntax=docker/dockerfile:1
#
# All-in-one Webstudio Builder image.
#
# One container runs:
#   - PostgreSQL 15 (+ pgtap, uuid-ossp)   127.0.0.1:5432
#   - PostgREST                            127.0.0.1:3001
#   - Webstudio Builder (Remix)            :80 (plain http)
# Assets are stored on the local filesystem. Everything persistent lives in /data.

ARG NODE_VERSION=22
ARG POSTGREST_VERSION=v12.2.12

FROM postgrest/postgrest:${POSTGREST_VERSION} AS postgrest

# ---------------------------------------------------------------------------
# Build stage: fetch the Webstudio monorepo and build the builder app
# ---------------------------------------------------------------------------
FROM node:${NODE_VERSION}-bookworm-slim AS build

RUN apt-get update \
  && apt-get install -y --no-install-recommends git ca-certificates openssl python3 make g++ \
  && rm -rf /var/lib/apt/lists/*

# Branch, tag or commit SHA of https://github.com/webstudio-is/webstudio
ARG WEBSTUDIO_REPO=https://github.com/webstudio-is/webstudio.git
# Pinned to a tested commit; bump deliberately.
ARG WEBSTUDIO_REF=6350169f12699cef5779af8a30bc54c081cc8ccb

WORKDIR /app
RUN git init -q . \
  && git remote add origin "$WEBSTUDIO_REPO" \
  && git fetch -q --depth 1 origin "$WEBSTUDIO_REF" \
  && git checkout -q FETCH_HEAD \
  && git log -1 --format='Building webstudio %H (%cd)'

RUN corepack enable && corepack install

ENV CI=true
RUN pnpm install --frozen-lockfile

RUN PRISMA_BINARY_TARGET='["native"]' pnpm --filter=@webstudio-is/prisma-client generate

# Upstream builds with the Vercel preset, which splits the server into several
# bundles. Drop it to get a single build/server/index.js for a plain Node server.
RUN sed -i '/presets: \[vercelPreset()\],/d' apps/builder/vite.config.ts \
  && ! grep -q 'presets: \[vercelPreset' apps/builder/vite.config.ts

# Serve over plain http: upstream forces https when deriving the main origin
# from a project subdomain (p-<projectId>.<host>), which breaks login on http.
RUN sed -i '/sourceUrl.protocol = "https";/d' packages/protocol/src/builder-api/url.ts \
  && ! grep -q 'protocol = "https"' packages/protocol/src/builder-api/url.ts

ENV NODE_OPTIONS=--max-old-space-size=8192
RUN pnpm --filter=@webstudio-is/builder build \
  && test -f apps/builder/build/server/index.js

# Upstream's committed .env holds development values (DEV_LOGIN, test tokens, ...).
# All runtime configuration comes from the entrypoint instead.
RUN rm -f apps/builder/.env

# ---------------------------------------------------------------------------
# Runtime stage
# ---------------------------------------------------------------------------
FROM node:${NODE_VERSION}-bookworm-slim

RUN apt-get update \
  && apt-get install -y --no-install-recommends \
    postgresql-15 postgresql-15-pgtap \
    supervisor tini openssl ca-certificates curl \
  && rm -rf /var/lib/apt/lists/*

COPY --from=postgrest /bin/postgrest /usr/local/bin/postgrest
COPY --from=build --chown=node:node /app /app

COPY --chown=node:node docker/server.mjs /app/apps/builder/server.mjs
COPY docker/supervisord.conf /etc/supervisor/supervisord.conf
COPY docker/entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh \
  # Uploaded assets are served from <cwd>/public/cgi/asset; keep them on the volume.
  && rm -rf /app/apps/builder/public/cgi/asset \
  && mkdir -p /app/apps/builder/public/cgi \
  && ln -s /data/assets /app/apps/builder/public/cgi/asset

ENV NODE_ENV=production \
    PATH=/usr/lib/postgresql/15/bin:$PATH \
    WEBSTUDIO_HOST=webstudio.localhost \
    PORT=80

VOLUME /data
EXPOSE 80

HEALTHCHECK --interval=30s --timeout=5s --start-period=120s --retries=3 \
  CMD curl -fsS -o /dev/null -H "Sec-Fetch-Mode: navigate" http://127.0.0.1:$PORT/login || exit 1

ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/entrypoint.sh"]
CMD ["supervisord", "-c", "/etc/supervisor/supervisord.conf"]
