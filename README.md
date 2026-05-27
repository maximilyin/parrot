# parrot

`parrot` is a PostgreSQL migrations library for Erlang applications.

It is designed to run during application startup, before the main supervision tree starts working with the database. If a migration cannot be applied safely, `parrot` crashes the caller so the application does not boot on top of an unexpected schema.

## Features

- Automatically creates the `migrations` history table when it is missing.
- Applies pending `*_upgrade.sql` files in version order.
- Supports explicit rollback through matching `*_downgrade.sql` files.
- Stores migration history with version, filename, checksum, timestamp, and success status.
- Validates migration filenames before connecting to the database.
- Validates checksums of already applied migrations before applying new ones.
- Logs a human-readable reason when migration startup fails.
- Uses a PostgreSQL advisory lock to prevent concurrent migration runs.
- Runs each migration in a transaction by default.
- Supports `-- parrot:no-transaction` for PostgreSQL statements that cannot run inside a transaction.
- Provides an `info` API for current version, applied migrations, pending migrations, and missing downgrades.

## API

Pass database connection options and the migrations directory directly to the library:

```erlang
parrot:migrate([
    {host, "localhost"},
    {port, 5432},
    {user, "postgres"},
    {password, "postgres"},
    {database, "postgres"},
    {migrations_dir, "priv/migrations"}
]).
```

Public functions:

- `parrot:migrate(Config)` applies pending upgrade migrations.
- `parrot:info(Config)` returns current version, applied upgrades, pending upgrades, and missing downgrades.
- `parrot:rollback(Config, TargetVersion)` explicitly applies downgrade files for versions greater than `TargetVersion`.

### Configuration

`Config` is a proplist. Database connection options are passed to `epgsql`, and `migrations_dir` tells `parrot` where SQL files are stored.

```erlang
Config = [
    {host, "localhost"},
    {port, 5432},
    {user, "postgres"},
    {password, "postgres"},
    {database, "postgres"},
    {migrations_dir, "priv/migrations"}
].
```

If `migrations_dir` is omitted, `parrot` uses `"priv/migrations"`.

The default path is relative to the current working directory of the Erlang process. In releases, pass an explicit path, for example:

```erlang
{migrations_dir, filename:join(code:priv_dir(my_app), "migrations")}
```

### Apply Migrations

Run pending upgrade migrations:

```erlang
ok = parrot:migrate(Config).
```

Use this during application startup. If a migration fails, `parrot:migrate/1` raises an exception with `erlang:error/1` and writes a readable reason to the log.

If the database is already up to date, `parrot:migrate/1` returns `ok` without applying anything.

If there are no applicable upgrade files, for example the migrations directory contains no `.sql` files or only files with invalid names, `parrot:migrate/1` logs the reason and crashes with `{migration_failed, {no_migrations_applied, Reason, Path}}`.

### Inspect Status

Read migration status without applying changes:

```erlang
{ok, Info} = parrot:info(Config).
```

Example result:

```erlang
[
    {current_version, "002"},
    {applied, [
        {"001", "001_init_upgrade.sql"},
        {"002", "002_add_accounts_upgrade.sql"}
    ]},
    {pending, [
        {"003", "003_add_indexes_upgrade.sql"}
    ]},
    {missing_downgrades, [
        {"003_add_indexes_upgrade.sql", "003_add_indexes_downgrade.sql"}
    ]},
    {warnings, [
        {missing_downgrade, "002_add_accounts_upgrade.sql", "002_add_accounts_downgrade.sql"}
    ]}
]
```

`warnings` contains non-blocking filename issues detected before startup, for example `{invalid_migration_suffix, File}` or `{missing_downgrade, UpgradeFile, ExpectedDowngradeFile}`.

### Roll Back

Rollback is explicit and never runs during normal startup:

```erlang
ok = parrot:rollback(Config, "001").
```

This applies downgrade files for successful versions greater than `001`, in reverse order. For example, if the current version is `003`, `parrot` applies:

```text
003_some_change_downgrade.sql
002_other_change_downgrade.sql
```

## Migration Files

Migration files live in the configured migrations directory and use this format:

```text
001_init_upgrade.sql
001_init_downgrade.sql
```

Each filename must match:

```text
NNN_name_upgrade.sql
NNN_name_downgrade.sql
```

Rules:

- `NNN` is a version prefix with at least 3 digits, for example `001`, `002`, or `1234`.
- `name` contains only letters, digits, underscores, and hyphens.
- Upgrade files must end with `_upgrade.sql`.
- Downgrade files must end with `_downgrade.sql`.

Upgrade files matching `*_upgrade.sql` are applied when their version is greater than the latest successful version in the `migrations` table.

Every upgrade should have a matching downgrade file with the same version and name. Missing downgrade files are reported as warnings in `parrot:info/1` and do not block startup.

Before `migrate/1` or `rollback/2` connect to PostgreSQL, `parrot` validates filenames in the migrations directory:

- `.sql` files without a version prefix are rejected.
- Duplicate upgrade files whose version prefixes share the same first 3 characters are rejected, for example `0010_first_upgrade.sql` and `001_second_upgrade.sql`.
- `.sql` files with a version prefix but an invalid suffix are reported as warnings and are not applied.

Before applying pending migrations, `parrot` validates checksums of previously successful migration files. If a file is missing or its checksum changed, startup fails.

Only one successful history row is allowed for the same `{version, name}` pair.

## Locking

Migration and rollback operations use a PostgreSQL advisory lock:

```sql
pg_advisory_lock(hashtext('parrot:migrations'))
```

This prevents two application instances from applying migrations concurrently.

## Transactions

Each upgrade file is executed in its own transaction by default. `parrot` runs the SQL file and records the successful history row in the same transaction.

Use this marker as the first meaningful line when a migration must run outside a transaction:

```sql
-- parrot:no-transaction
```

This is intended for PostgreSQL operations that cannot run inside `BEGIN` / `COMMIT`, for example `CREATE INDEX CONCURRENTLY`. Non-transactional migrations record history only after successful execution; failed attempts are recorded with `success = false` when possible.

## Downgrade Policy

Downgrade migrations are not applied during normal startup. Startup only moves the database forward by applying pending `*_upgrade.sql` files.

Downgrades should be executed only by an explicit rollback API or CLI command, for example when reverting a failed release, rolling back a staging environment, or testing migration reversibility. They should not run automatically when the application code version is lower than the database version because that can silently destroy data.

Rollback is append-only in the history table: a successful downgrade records its own row with `name` set to the full `*_downgrade.sql` filename. The current version is calculated from successful upgrade and downgrade records.

## History Table

If the `migrations` table does not exist, `parrot` creates it automatically:

```sql
CREATE TABLE migrations (
    id SERIAL PRIMARY KEY,
    version VARCHAR(64) NOT NULL,
    name VARCHAR(512) NOT NULL,
    checksum VARCHAR(64) NOT NULL,
    created_date TIMESTAMP NOT NULL DEFAULT NOW(),
    success BOOLEAN NOT NULL
);
```

`name` stores the full applied migration filename, for example `001_init_upgrade.sql` or `001_init_downgrade.sql`.

`parrot` also creates a unique partial index for successful history rows:

```sql
CREATE UNIQUE INDEX IF NOT EXISTS migrations_success_name_idx
ON migrations (version, name)
WHERE success = TRUE;
```

If a migration fails, `parrot` records the failed attempt with `success = false`, logs the reason, and crashes with `erlang:error/1`. This prevents the main application from starting on top of a partially migrated schema.

Failure reasons are written to the Erlang log with `error_logger`, not stored in the `migrations` table. SQL execution errors are logged from the migration runner; validation and startup failures are logged from `parrot:migrate/1` and `parrot:rollback/2`.

Common startup exceptions:

- `{validation_failed, Reason}` for invalid config, unreadable migrations directory, invalid filenames, or checksum mismatch.
- `{migration_failed, {no_migrations_applied, Reason, Path}}` when no upgrade migration could be applied.
- `{migration_failed, File, Reason}` when a migration file could not be read or its SQL failed.

## Tests

Run unit tests:

```sh
make eunit
```

The integration test that creates the `migrations` table and applies a real SQL migration is disabled by default. Enable it with Docker; the test starts an isolated PostgreSQL container, runs the migration, and removes the container during cleanup:

```sh
PARROT_TEST_DOCKER=1 \
make eunit
```
