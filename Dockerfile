# tapes + Postgres in one image, booted as a smolvm microVM.
#
# tapes (the server) is Postgres-only, so the database rides along inside the
# VM. Nothing here is smolvm-specific; the same image runs under plain Docker.
FROM postgres:16-alpine

ARG TAPES_VERSION=latest
ARG TAPESCTL_VERSION=latest

RUN apk add --no-cache bash curl jq ca-certificates

# Linux build of tapes (server) and tapesctl (client) for the guest's CPU arch.
RUN set -eux; \
    case "$(uname -m)" in aarch64|arm64) ARCH=arm64 ;; x86_64|amd64) ARCH=amd64 ;; *) echo "unsupported arch" >&2; exit 1 ;; esac; \
    curl -fsSL "https://download.tapes.dev/${TAPES_VERSION}/linux/${ARCH}/tapes" -o /usr/local/bin/tapes; \
    curl -fsSL "https://download.tapes.dev/tapesctl/${TAPESCTL_VERSION}/linux/${ARCH}/tapesctl" -o /usr/local/bin/tapesctl; \
    chmod +x /usr/local/bin/tapes /usr/local/bin/tapesctl; \
    tapes version; tapesctl version

ENV POSTGRES_USER=tapes \
    POSTGRES_PASSWORD=tapes \
    POSTGRES_DB=tapes \
    PGDATA=/var/lib/postgresql/data \
    TAPES_OUT=/var/tapes/out \
    TAPES_API_URL=http://127.0.0.1:8081 \
    TAPES_INGEST_URL=http://127.0.0.1:8082

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh
ENTRYPOINT ["/entrypoint.sh"]
