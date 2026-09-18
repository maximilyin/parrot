#!/usr/bin/env bash
#
# Runs the full parrot test suite (unit + fake-driver + integration)
# against real PostgreSQL and MariaDB containers.
#
# Isolation:
# - Database servers run in throwaway containers on a private docker
#   network. Ports are not published to the host, so a local PostgreSQL
#   on :5432 or MySQL on :3306 is never used.
# - Tests always run inside erlang:27 on that same network, even when
#   a local `erl` is installed. Host OTP/NIFs do not participate.
# - Containers, the network and all names are unique per run and
#   removed on exit, even on failure.

set -euo pipefail

cd "$(dirname "$0")/.."

SUFFIX=$$
NETWORK="parrot-it-net-${SUFFIX}"
PG_CONTAINER="parrot-it-pg-${SUFFIX}"
MYSQL_CONTAINER="parrot-it-mysql-${SUFFIX}"

cleanup() {
    docker rm -f "$PG_CONTAINER" "$MYSQL_CONTAINER" >/dev/null 2>&1 || true
    docker network rm "$NETWORK" >/dev/null 2>&1 || true
}
trap cleanup EXIT

docker network create "$NETWORK" >/dev/null

docker run -d --name "$PG_CONTAINER" --network "$NETWORK" \
    -e POSTGRES_PASSWORD=postgres \
    postgres:16-alpine >/dev/null

docker run -d --name "$MYSQL_CONTAINER" --network "$NETWORK" \
    -e MARIADB_ROOT_PASSWORD=parrot \
    mariadb:11 >/dev/null

echo "Waiting for PostgreSQL to become ready..."
for attempt in $(seq 1 60); do
    if docker exec "$PG_CONTAINER" pg_isready -U postgres >/dev/null 2>&1; then
        break
    fi
    if [ "$attempt" -eq 60 ]; then
        echo "PostgreSQL did not become ready in time" >&2
        exit 1
    fi
    sleep 1
done

echo "Waiting for MariaDB to become ready..."
for attempt in $(seq 1 60); do
    # Force TCP so the temporary socket-only server used during the
    # image's initialization phase does not count as ready.
    if docker exec "$MYSQL_CONTAINER" \
        mariadb -uroot -pparrot -h127.0.0.1 --protocol=tcp -e 'SELECT 1' >/dev/null 2>&1; then
        break
    fi
    if [ "$attempt" -eq 60 ]; then
        echo "MariaDB did not become ready in time" >&2
        exit 1
    fi
    sleep 1
done

docker run --rm --network "$NETWORK" \
    -v "$PWD":/work -w /work -e HOME=/tmp \
    --user "$(id -u):$(id -g)" \
    -e PARROT_TEST_PG_HOST="$PG_CONTAINER" \
    -e PARROT_TEST_PG_PORT=5432 \
    -e PARROT_TEST_MYSQL_HOST="$MYSQL_CONTAINER" \
    -e PARROT_TEST_MYSQL_PORT=3306 \
    -e PARROT_TEST_MYSQL_PASSWORD=parrot \
    erlang:27 make eunit
