-module(parrot_driver_epgsql).

%% PostgreSQL driver backed by the epgsql client.

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

-ifdef(TEST).
-export([normalize_squery_result/1]).
-endif.

-define(TABLE_NAME, <<"migrations">>).

-define(CREATE_MIGRATIONS_TABLE, <<
    "CREATE TABLE IF NOT EXISTS ", ?TABLE_NAME/binary, " ("
        "id SERIAL PRIMARY KEY,"
        "version VARCHAR(64) NOT NULL,"
        "name VARCHAR(512) NOT NULL,"
        "checksum VARCHAR(64) NOT NULL,"
        "created_date TIMESTAMP NOT NULL DEFAULT NOW(),"
        "success BOOLEAN NOT NULL"
    ")"
>>).

-define(CREATE_SUCCESS_INDEX, <<
    "CREATE UNIQUE INDEX IF NOT EXISTS migrations_success_name_idx "
    "ON ", ?TABLE_NAME/binary, " (version, name) WHERE success = TRUE"
>>).

-define(INSERT_MIGRATION_RESULT, <<
    "INSERT INTO ", ?TABLE_NAME/binary, " (version, name, checksum, success) VALUES ($1, $2, $3, $4)"
>>).

-define(SELECT_SUCCESS_HISTORY, <<
    "SELECT version, name, checksum FROM ", ?TABLE_NAME/binary, " WHERE success = TRUE ORDER BY id ASC"
>>).

-define(LOCK_MIGRATIONS, <<"SELECT pg_advisory_lock(hashtext('parrot:migrations'))">>).

-define(UNLOCK_MIGRATIONS, <<"SELECT pg_advisory_unlock(hashtext('parrot:migrations'))">>).

validate_config(Config) ->
    parrot_validation:validate_config(Config).

connect(Config) ->
    Host = proplists:get_value(host, Config, "localhost"),
    Port = proplists:get_value(port, Config, 5432),
    User = proplists:get_value(user, Config, "postgres"),
    Password = proplists:get_value(password, Config, "postgres"),
    Database = proplists:get_value(database, Config, "postgres"),
    Opts = [{port, Port}, {database, Database}],
    epgsql:connect(Host, User, Password, Opts).

close(Connection) ->
    %% epgsql links the connection process to the caller.
    unlink(Connection),
    catch epgsql:close(Connection),
    receive
        {'EXIT', Connection, _Reason} ->
            ok
    after 0 ->
        ok
    end,
    ok.

ensure_schema(Connection) ->
    case epgsql:squery(Connection, ?CREATE_MIGRATIONS_TABLE) of
        {error, Reason} ->
            {error, Reason};
        _Result ->
            ensure_success_index(Connection)
    end.

lock(Connection) ->
    exec_sql(Connection, ?LOCK_MIGRATIONS).

unlock(Connection) ->
    _ = exec_sql(Connection, ?UNLOCK_MIGRATIONS),
    ok.

begin_tx(Connection) ->
    exec_sql(Connection, <<"BEGIN">>).

commit(Connection) ->
    exec_sql(Connection, <<"COMMIT">>).

rollback(Connection) ->
    exec_sql(Connection, <<"ROLLBACK">>).

run_migration(Connection, Migration) ->
    normalize_squery_result(epgsql:squery(Connection, Migration)).

%% epgsql:squery/2 returns a list of per-statement results when the SQL
%% contains several statements; a failure mid-file shows up as an
%% {error, Reason} element of that list, not as a top-level error.
normalize_squery_result({error, Reason}) ->
    {error, Reason};
normalize_squery_result(Results) when is_list(Results) ->
    case first_error(Results) of
        undefined ->
            {ok, Results};
        {error, Reason} ->
            {error, Reason}
    end;
normalize_squery_result(Result) ->
    {ok, Result}.

first_error([]) ->
    undefined;
first_error([{error, Reason} | _Rest]) ->
    {error, Reason};
first_error([_Result | Rest]) ->
    first_error(Rest).

record_migration(Connection, Version, Name, Checksum, Success) ->
    case epgsql:equery(Connection, ?INSERT_MIGRATION_RESULT, [Version, Name, Checksum, Success]) of
        {ok, _} ->
            ok;
        {error, Reason} ->
            {error, Reason}
    end.

get_success_history(Connection) ->
    case epgsql:squery(Connection, ?SELECT_SUCCESS_HISTORY) of
        {ok, _, Rows} ->
            {ok, [{normalize_string(Version), normalize_string(Name), normalize_string(Checksum)}
                  || {Version, Name, Checksum} <- Rows]};
        {error, Reason} ->
            {error, Reason}
    end.

ensure_success_index(Connection) ->
    case epgsql:squery(Connection, ?CREATE_SUCCESS_INDEX) of
        {error, Reason} ->
            {error, Reason};
        _Result ->
            ok
    end.

exec_sql(Connection, Sql) ->
    case epgsql:squery(Connection, Sql) of
        {error, Reason} ->
            {error, Reason};
        _Result ->
            ok
    end.

normalize_string(Value) when is_binary(Value) ->
    binary_to_list(Value);
normalize_string(Value) ->
    Value.
