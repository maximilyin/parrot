-module(parrot_driver_sqlite).

%% SQLite driver backed by the esqlite client (0.8.x API).
%%
%% Differences from the server-based drivers:
%% - The only required connection option is `database', the path to the
%%   database file.
%% - lock/1 and unlock/1 are no-ops: SQLite serializes writers itself and
%%   there is no server to share an advisory lock through. A busy timeout
%%   is set on the connection so concurrent local runs wait instead of
%%   failing immediately.

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
        "id INTEGER PRIMARY KEY AUTOINCREMENT,"
        "version VARCHAR(64) NOT NULL,"
        "name VARCHAR(512) NOT NULL,"
        "checksum VARCHAR(64) NOT NULL,"
        "created_date TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,"
        "success BOOLEAN NOT NULL"
    ")"
>>).

-define(CREATE_SUCCESS_INDEX, <<
    "CREATE UNIQUE INDEX IF NOT EXISTS migrations_success_name_idx "
    "ON migrations (version, name) WHERE success = 1"
>>).

-define(INSERT_MIGRATION_RESULT, <<
    "INSERT INTO migrations (version, name, checksum, success) VALUES (?1, ?2, ?3, ?4)"
>>).

-define(SELECT_SUCCESS_HISTORY, <<
    "SELECT version, name, checksum FROM migrations WHERE success = 1 ORDER BY id ASC"
>>).

-define(BUSY_TIMEOUT_MS, 60000).

validate_config(Config) ->
    case proplists:get_value(database, Config) of
        undefined ->
            {error, {missing_config_field, database}};
        Value when is_list(Value), Value =/= [] ->
            ok;
        Value when is_binary(Value), byte_size(Value) > 0 ->
            ok;
        _ ->
            {error, {invalid_config_field, database, non_empty_string_or_binary}}
    end.

connect(Config) ->
    Database = proplists:get_value(database, Config),
    case esqlite3:open(to_filename(Database)) of
        {ok, Connection} ->
            BusyTimeout = integer_to_binary(?BUSY_TIMEOUT_MS),
            case esqlite3:exec(Connection, <<"PRAGMA busy_timeout = ", BusyTimeout/binary>>) of
                ok ->
                    {ok, Connection};
                {error, Reason} ->
                    catch esqlite3:close(Connection),
                    {error, Reason}
            end;
        {error, Reason} ->
            {error, Reason}
    end.

close(Connection) ->
    catch esqlite3:close(Connection),
    ok.

ensure_schema(Connection) ->
    case exec_sql(Connection, ?CREATE_MIGRATIONS_TABLE) of
        ok ->
            ensure_success_index(Connection);
        {error, Reason} ->
            {error, Reason}
    end.

lock(_Connection) ->
    ok.

unlock(_Connection) ->
    ok.

begin_tx(Connection) ->
    exec_sql(Connection, <<"BEGIN">>).

commit(Connection) ->
    exec_sql(Connection, <<"COMMIT">>).

rollback(Connection) ->
    exec_sql(Connection, <<"ROLLBACK">>).

run_migration(Connection, Migration) ->
    case esqlite3:exec(Connection, Migration) of
        ok ->
            {ok, executed};
        {error, Reason} ->
            {error, describe_error(Connection, Reason)}
    end.

record_migration(Connection, Version, Name, Checksum, Success) ->
    Params = [to_binary(Version), to_binary(Name), to_binary(Checksum), boolean_to_integer(Success)],
    case esqlite3:q(Connection, ?INSERT_MIGRATION_RESULT, Params) of
        {error, Reason} ->
            {error, describe_error(Connection, Reason)};
        _Rows ->
            ok
    end.

get_success_history(Connection) ->
    case esqlite3:q(Connection, ?SELECT_SUCCESS_HISTORY) of
        {error, Reason} ->
            {error, describe_error(Connection, Reason)};
        Rows ->
            {ok, [{normalize_string(Version), normalize_string(Name), normalize_string(Checksum)}
                  || [Version, Name, Checksum] <- Rows]}
    end.

ensure_success_index(Connection) ->
    exec_sql(Connection, ?CREATE_SUCCESS_INDEX).

exec_sql(Connection, Sql) ->
    case esqlite3:exec(Connection, Sql) of
        ok ->
            ok;
        {error, Reason} ->
            {error, describe_error(Connection, Reason)}
    end.

describe_error(Connection, Reason) ->
    case catch esqlite3:error_info(Connection) of
        #{errmsg := _} = Info ->
            {sqlite_error, Reason, Info};
        _ ->
            {sqlite_error, Reason}
    end.

to_filename(Value) when is_binary(Value) ->
    binary_to_list(Value);
to_filename(Value) when is_list(Value) ->
    Value.

to_binary(Value) when is_binary(Value) ->
    Value;
to_binary(Value) when is_list(Value) ->
    unicode:characters_to_binary(Value).

boolean_to_integer(true) ->
    1;
boolean_to_integer(false) ->
    0.

normalize_string(Value) when is_binary(Value) ->
    binary_to_list(Value);
normalize_string(Value) ->
    Value.
