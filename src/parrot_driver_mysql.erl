-module(parrot_driver_mysql).

%% MySQL / MariaDB driver backed by the mysql-otp client.
%%
%% Differences from the PostgreSQL driver:
%% - Locking uses GET_LOCK / RELEASE_LOCK instead of advisory locks.
%% - MySQL does not support partial indexes, so the unique index on
%%   successful history rows is not created. Uniqueness is still
%%   guaranteed in practice because migration runs are serialized by
%%   the named lock.

-behaviour(parrot_driver).

-export([
    validate_config/1,
    connect/1,
    close/1,
    ensure_schema/1,
    lock/1,
    unlock/1,
    begin_tx/1,
    commit/1,
    rollback/1,
    run_migration/2,
    record_migration/5,
    get_success_history/1
]).

-define(CREATE_MIGRATIONS_TABLE, <<
    "CREATE TABLE IF NOT EXISTS migrations ("
        "id INT AUTO_INCREMENT PRIMARY KEY,"
        "version VARCHAR(64) NOT NULL,"
        "name VARCHAR(512) NOT NULL,"
        "checksum VARCHAR(64) NOT NULL,"
        "created_date TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,"
        "success BOOLEAN NOT NULL"
    ")"
>>).

-define(INSERT_MIGRATION_RESULT, <<
    "INSERT INTO migrations (version, name, checksum, success) VALUES (?, ?, ?, ?)"
>>).

-define(SELECT_SUCCESS_HISTORY, <<
    "SELECT version, name, checksum FROM migrations WHERE success = TRUE ORDER BY id ASC"
>>).

%% One day, effectively "wait forever" while staying compatible with
%% both MySQL and MariaDB timeout semantics.
-define(LOCK_TIMEOUT_SECONDS, 86400).

-define(UNLOCK_MIGRATIONS, <<"SELECT RELEASE_LOCK('parrot:migrations')">>).

validate_config(Config) ->
    parrot_validation:validate_config(Config).

connect(Config) ->
    Options = [
        {host, proplists:get_value(host, Config, "localhost")},
        {port, proplists:get_value(port, Config, 3306)},
        {user, proplists:get_value(user, Config, "root")},
        {password, proplists:get_value(password, Config, "")},
        {database, proplists:get_value(database, Config)}
    ],
    case mysql:start_link(Options) of
        {ok, Connection} ->
            {ok, Connection};
        ignore ->
            {error, ignore};
        {error, Reason} ->
            {error, Reason}
    end.

close(Connection) ->
    %% mysql:start_link/1 links the connection process to the caller.
    unlink(Connection),
    catch mysql:stop(Connection),
    receive
        {'EXIT', Connection, _Reason} ->
            ok
    after 0 ->
        ok
    end,
    ok.

ensure_schema(Connection) ->
    %% MySQL intentionally has no unique index on successful history
    %% rows (no partial index support); see module comment.
    exec_sql(Connection, ?CREATE_MIGRATIONS_TABLE).

lock(Connection) ->
    Timeout = integer_to_binary(?LOCK_TIMEOUT_SECONDS),
    Sql = <<"SELECT GET_LOCK('parrot:migrations', ", Timeout/binary, ")">>,
    case mysql:query(Connection, Sql, lock_query_timeout()) of
        {ok, _Columns, [[1]]} ->
            ok;
        {ok, _Columns, Rows} ->
            {error, {lock_not_acquired, Rows}};
        {error, Reason} ->
            {error, Reason}
    end.

unlock(Connection) ->
    catch mysql:query(Connection, ?UNLOCK_MIGRATIONS),
    ok.

begin_tx(Connection) ->
    exec_sql(Connection, <<"BEGIN">>).

commit(Connection) ->
    exec_sql(Connection, <<"COMMIT">>).

rollback(Connection) ->
    exec_sql(Connection, <<"ROLLBACK">>).

run_migration(Connection, Migration) ->
    case mysql:query(Connection, Migration) of
        {error, Reason} ->
            {error, Reason};
        ok ->
            {ok, ok};
        {ok, _, _} = Result ->
            {ok, Result};
        {ok, _} = Result ->
            {ok, Result}
    end.

record_migration(Connection, Version, Name, Checksum, Success) ->
    Params = [to_binary(Version), to_binary(Name), to_binary(Checksum), boolean_to_integer(Success)],
    case mysql:query(Connection, ?INSERT_MIGRATION_RESULT, Params) of
        ok ->
            ok;
        {error, Reason} ->
            {error, Reason}
    end.

get_success_history(Connection) ->
    case mysql:query(Connection, ?SELECT_SUCCESS_HISTORY) of
        {ok, _Columns, Rows} ->
            {ok, [{normalize_string(Version), normalize_string(Name), normalize_string(Checksum)}
                  || [Version, Name, Checksum] <- Rows]};
        {error, Reason} ->
            {error, Reason}
    end.

exec_sql(Connection, Sql) ->
    case mysql:query(Connection, Sql) of
        {error, Reason} ->
            {error, Reason};
        _Result ->
            ok
    end.

lock_query_timeout() ->
    %% Give the client a margin above the server-side lock timeout.
    timer:seconds(?LOCK_TIMEOUT_SECONDS + 60).

boolean_to_integer(true) ->
    1;
boolean_to_integer(false) ->
    0.

to_binary(Value) when is_binary(Value) ->
    Value;
to_binary(Value) when is_list(Value) ->
    unicode:characters_to_binary(Value).

normalize_string(Value) when is_binary(Value) ->
    binary_to_list(Value);
normalize_string(Value) ->
    Value.
