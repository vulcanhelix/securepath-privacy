# Self-hosted Langfuse

This is a standalone Langfuse v4 Docker Compose stack. It is intentionally
separate from `staging/docker-compose.yml`; do not merge the services into the
SecurePath application stack.

The stack includes the Langfuse web server and worker, PostgreSQL, Redis,
ClickHouse, and MinIO S3-compatible object storage. Langfuse's current
self-hosting guidance describes Compose as suitable for testing and low-scale
VM deployments, not as a highly available or backed-up production topology.
The documented baseline is approximately 4 CPU cores, 16 GiB RAM, and 100 GiB
storage, with trace data growth monitored separately.

## Start

Copy the variables below into a deployment-only `.env` file. Keep that file
outside Git and generate fresh values for every deployment:

```dotenv
NEXTAUTH_URL=http://localhost:3000
DATABASE_URL=postgresql://postgres:change-me@postgres:5432/postgres
POSTGRES_PASSWORD=change-me
SALT=change-me
ENCRYPTION_KEY=generate-64-hex-characters
NEXTAUTH_SECRET=change-me
CLICKHOUSE_PASSWORD=change-me
REDIS_AUTH=change-me
MINIO_ROOT_USER=minio
MINIO_ROOT_PASSWORD=change-me
```

Generate `ENCRYPTION_KEY` with `openssl rand -hex 32`. Then run:

```sh
docker compose --env-file .env -f docker-compose.yml up -d
```

Only the web UI and, if needed, the MinIO API should be exposed through a
carefully restricted reverse proxy. PostgreSQL, Redis, ClickHouse, and the
worker are bound to loopback or the Compose network. This Compose topology has
no automatic HA, backup, or disaster-recovery guarantees; arrange and test
those separately before relying on it for audit data.

Create a Langfuse project in the web UI and provide its public and secret keys
to SecurePath using the application environment variables documented in
`CLAUDE.md`. The SecurePath tracing integration is disabled unless all three
of `LANGFUSE_BASE_URL`, `LANGFUSE_PUBLIC_KEY`, and `LANGFUSE_SECRET_KEY` are
present.
