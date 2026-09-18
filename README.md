# parrot

`parrot` is a database migrations library for Erlang applications. PostgreSQL, MySQL, MariaDB, and SQLite are supported out of the box through pluggable drivers.

It is designed to run during application startup, before the main supervision tree starts working with the database. If a migration cannot be applied safely, `parrot` crashes the caller so the application does not boot on top of an unexpected schema.

## Features

- Pluggable database drivers: PostgreSQL (default), MySQL/MariaDB, SQLite, or a custom module implementing the `parrot_driver` behaviour.
- Automatically creates the `migrations` history table when it is missing.
- Applies pending `*_upgrade.sql` files in version order.
- Supports explicit rollback through matching `*_downgrade.sql` files.
- Stores migration history with version, filename, checksum, timestamp, and success status.
- Validates migration filenames before connecting to the database.
- Validates checksums of already applied migrations before applying new ones.
- Logs a human-readable reason when migration startup fails.
- Uses a database-level lock (PostgreSQL advisory lock, MySQL `GET_LOCK`) to prevent concurrent migration runs.
- Runs each migration in a transaction by default.
- Supports `-- parrot:no-transaction` for statements that cannot run inside a transaction.
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

`Config` is a proplist. `driver` selects the database driver, connection options are passed to the underlying client, and `migrations_dir` tells `parrot` where SQL files are stored.

```erlang
Config = [
    {driver, postgres},
    {host, "localhost"},
    {port, 5432},
    {user, "postgres"},
    {password, "postgres"},
    {database, "postgres"},
    {migrations_dir, "priv/migrations"}
].
```

If `driver` is omitted, `parrot` uses `postgres`. If `migrations_dir` is omitted, `parrot` uses `"priv/migrations"`.

The default path is relative to the current working directory of the Erlang process. In releases, pass an explicit path, for example:

```erlang
{migrations_dir, filename:join(code:priv_dir(my_app), "migrations")}
```

### Drivers

| `driver` value | Database | Erlang client used |
|---|---|---|
| `postgres` (default) | PostgreSQL | [`epgsql`](https://github.com/epgsql/epgsql) |
| `mysql` or `mariadb` | MySQL / MariaDB | [`mysql-otp`](https://github.com/mysql-otp/mysql-otp) |
| `sqlite` | SQLite | [`esqlite`](https://github.com/mmzeeman/esqlite) 0.8.x |
| any other atom | custom | your module implementing the `parrot_driver` behaviour |

`parrot` declares all three clients (`epgsql` 4.8.0, `mysql` 1.9.0, `esqlite` 0.8.9) as its own dependencies, so host applications get them transitively and do not need to add anything manually. Note that `esqlite` contains a NIF, so building `parrot` requires a C toolchain even if you only use PostgreSQL.

PostgreSQL and MySQL/MariaDB use the same connection options: `host`, `port`, `user`, `password`, `database`.

SQLite only needs the path to the database file:

```erlang
Config = [
    {driver, sqlite},
    {database, "/var/lib/my_app/my_app.db"},
    {migrations_dir, "priv/migrations"}
].
```

To support another database, implement the `parrot_driver` behaviour (connection lifecycle, history table DDL, locking, transaction control, and query execution) and pass the module name in `driver`:

```erlang
{driver, my_custom_driver}
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

Migration and rollback operations take a database-level lock so that two application instances cannot apply migrations concurrently:

- PostgreSQL: `pg_advisory_lock(hashtext('parrot:migrations'))`.
- MySQL / MariaDB: `GET_LOCK('parrot:migrations', ...)`.
- SQLite: no explicit lock; SQLite serializes writers itself, and the driver sets a busy timeout so concurrent local runs wait instead of failing.

## Transactions

Each upgrade file is executed in its own transaction by default. `parrot` runs the SQL file and records the successful history row in the same transaction.

Use this marker as the first meaningful line when a migration must run outside a transaction:

```sql
-- parrot:no-transaction
```

This is intended for operations that cannot run inside `BEGIN` / `COMMIT`, for example `CREATE INDEX CONCURRENTLY` in PostgreSQL. Note that MySQL DDL statements cause implicit commits, so downgrade files are especially important there. Non-transactional migrations record history only after successful execution; failed attempts are recorded with `success = false` when possible.

## Downgrade Policy

Downgrade migrations are not applied during normal startup. Startup only moves the database forward by applying pending `*_upgrade.sql` files.

Downgrades should be executed only by an explicit rollback API or CLI command, for example when reverting a failed release, rolling back a staging environment, or testing migration reversibility. They should not run automatically when the application code version is lower than the database version because that can silently destroy data.

Rollback is append-only in the history table: a successful downgrade records its own row with `name` set to the full `*_downgrade.sql` filename. The current version is calculated from successful upgrade and downgrade records.

## History Table

If the `migrations` table does not exist, `parrot` creates it automatically. The exact DDL is driver-specific; for PostgreSQL:

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

MySQL/MariaDB uses `INT AUTO_INCREMENT` and `CURRENT_TIMESTAMP`, SQLite uses `INTEGER PRIMARY KEY AUTOINCREMENT`; the columns are the same.

`name` stores the full applied migration filename, for example `001_init_upgrade.sql` or `001_init_downgrade.sql`.

On PostgreSQL and SQLite, `parrot` also creates a unique partial index for successful history rows:

```sql
CREATE UNIQUE INDEX IF NOT EXISTS migrations_success_name_idx
ON migrations (version, name)
WHERE success = TRUE;
```

MySQL/MariaDB does not support partial indexes, so this index is not created there; uniqueness of successful rows is still guaranteed in practice because migration runs are serialized by `GET_LOCK`.

If a migration fails, `parrot` records the failed attempt with `success = false`, logs the reason, and crashes with `erlang:error/1`. This prevents the main application from starting on top of a partially migrated schema.

Failure reasons are written to the Erlang log with `error_logger`, not stored in the `migrations` table. SQL execution errors are logged from the migration runner; validation and startup failures are logged from `parrot:migrate/1` and `parrot:rollback/2`.

Common startup exceptions:

- `{validation_failed, Reason}` for invalid config, unreadable migrations directory, invalid filenames, or checksum mismatch.
- `{migration_failed, {no_migrations_applied, Reason, Path}}` when no upgrade migration could be applied.
- `{migration_failed, File, Reason}` when a migration file could not be read or its SQL failed.

## Tests

Run unit tests, fake-driver tests, and the SQLite integration tests (no Docker or database server needed). Checksum mismatch runs on all drivers; the matrix also covers sequential upgrade/rollback and concurrent PostgreSQL/MySQL migrators:

```sh
make eunit
```

Run the full integration matrix against real databases. This starts throwaway PostgreSQL and MariaDB containers on a private Docker network (ports are not published to the host, so a local PostgreSQL or MySQL is never used), runs the suite inside an `erlang:27` container on that network, and removes everything afterwards, even on failure:

```sh
make tests-integration
```

Expected `error_logger` lines for `undefined_table`, `checksum_mismatch`, and `enoent` come from negative scenarios; they are not failures by themselves. A real failure is a non-zero `make` exit or an Erlang VM abort.

The PostgreSQL and MySQL/MariaDB integration tests are skipped unless the corresponding `*_HOST` variable is set, so you can also point them at your own databases:

| Variable | Default | Meaning |
|---|---|---|
| `PARROT_TEST_PG_HOST` | unset (tests skipped) | PostgreSQL host |
| `PARROT_TEST_PG_PORT` | `5432` | PostgreSQL port |
| `PARROT_TEST_MYSQL_HOST` | unset (tests skipped) | MySQL/MariaDB host |
| `PARROT_TEST_MYSQL_PORT` | `3306` | MySQL/MariaDB port |
| `PARROT_TEST_MYSQL_PASSWORD` | `parrot` | MySQL/MariaDB `root` password |

PostgreSQL credentials are `postgres`/`postgres`. Each test scenario creates and drops its own uniquely named database (`parrot_it_*`), so the configured server is left unchanged.
