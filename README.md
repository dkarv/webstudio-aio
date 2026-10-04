# Webstudio AIO

Self-hosted [Webstudio](https://github.com/webstudio-is/webstudio) Builder in a single Docker container,
served over plain HTTP.

| Component            | Listens on        |
| -------------------- | ----------------- |
| PostgreSQL 15        | 127.0.0.1:5432    |
| PostgREST            | 127.0.0.1:3001    |
| Webstudio Builder    | :80 (`PORT`)      |

Uploaded assets are stored on the local filesystem. Everything persistent (database, assets,
secrets) lives in the `/data` volume.

## Quick start

```sh
docker compose up -d --build
docker compose logs webstudio | grep "Login secret"
```

Open <http://webstudio.localhost> in Chrome or Firefox and log in with any email address and the
login secret from the logs.

To pin a Webstudio version, set the build arg `WEBSTUDIO_REF` to a branch, tag or commit SHA.

## Why `*.localhost`

The builder opens every project on its own subdomain (`p-<projectId>.<host>`). It also relies on
browser features that only work in a "secure context": `__Host-`/`Secure` session cookies and
`Sec-Fetch-*` request headers, which it uses for CSRF protection. Over plain HTTP, browsers only treat
`localhost` and `*.localhost` as secure, and they resolve `*.localhost` to 127.0.0.1 without any DNS
setup.

Using a regular hostname (e.g. `http://webstudio.lan`) over plain HTTP won't work: login fails
because the browser drops the cookies and the request headers.

To use an instance on a remote server, tunnel the port and keep the `localhost` hostname:

```sh
ssh -L 80:localhost:80 user@server   # then open http://webstudio.localhost
```

## Behind a reverse proxy (https)

With a real domain, put a TLS-terminating proxy in front and set `BEHIND_PROXY=true`:

- The proxy serves `<host>` and `*.<host>` (wildcard certificate) and forwards to the container's
  `PORT`, with `X-Forwarded-Proto`/`X-Forwarded-Host` (Caddy does this by default).
- During login the builder calls `https://<host>` from inside the container, so `<host>` must
  resolve to the proxy from there, e.g. as a network alias of the proxy container.

```caddyfile
webstudio.example.com, *.webstudio.example.com {
    reverse_proxy webstudio:3000
}
```

## Configuration

| Variable          | Default               | Description |
| ----------------- | --------------------- | ----------- |
| `WEBSTUDIO_HOST`  | `webstudio.localhost` | Hostname you open in the browser. |
| `PORT`            | `80`                  | Port the builder listens on. Publish it on the same host port (`-p 8080:8080` with `PORT=8080`), because the builder calls its own public URL during login. |
| `BEHIND_PROXY`    | `false`               | `true` when an https reverse proxy is in front (see above). `PORT` is then only the internal port. |
| `AUTH_SECRET`     | generated             | Session secret, and the password for the login form. |
| `DEV_LOGIN`       | `true`                | Email + secret login. Set to `false` once OAuth is configured. |
| `GH_CLIENT_ID` / `GH_CLIENT_SECRET`         | | GitHub OAuth login |
| `GOOGLE_CLIENT_ID` / `GOOGLE_CLIENT_SECRET` | | Google OAuth login |
| `PLANS`           | a "Pro" plan with high limits | Plan definitions (JSON). |
| `FEATURE_FLAGS`   | empty                 | Comma-separated feature flags (`*` enables all). |
| `MAX_UPLOAD_SIZE` | upstream default      | Max asset upload size in MB. |
| `S3_*`            |                       | Use S3 for assets instead of the local filesystem. |

Generated secrets are stored in `/data/secrets`. Database migrations run on each start.

## Backups

Every 6 hours, a consistent database dump is written to `/data/backup/webstudio.dump`
(`pg_restore` format). Back up `/data`. Leave out `/data/postgres` if your backup tool
can't snapshot it consistently; the dump plus `/data/assets` and `/data/secrets` is enough to restore.

## Limitations

- Publishing to custom domains relies on Webstudio's hosted publisher service, which isn't
  included. Export a project with the Webstudio CLI and host it yourself instead.
- Plain HTTP only works on `localhost` hostnames (see above).
