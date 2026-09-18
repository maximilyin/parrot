-module(parrot_driver).

%% Behaviour for database-specific drivers plus dispatch helpers.
%%
%% A driver hides everything that is not portable between databases:
%% connecting, the history table DDL, locking, transaction control and
%% parameter placeholder syntax. The migration logic in parrot_migration
%% only talks to this module and never to a database client directly.
%%
%% The connection handle returned by connect/1 is `{DriverModule, Connection}'
%% and must be passed to every other function in this module.

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

-type config() :: [{atom(), term()}].
-type connection() :: term().
-type handle() :: {module(), connection()}.
-type history_row() :: {Version :: string(), Name :: string(), Checksum :: string()}.

-export_type([config/0, connection/0, handle/0, history_row/0]).

%% Connection lifecycle.
-callback validate_config(config()) -> ok | {error, term()}.
-callback connect(config()) -> {ok, connection()} | {error, term()}.
-callback close(connection()) -> ok.

%% History schema and rows. get_success_history/1 must return rows ordered
%% by insertion order with version, name and checksum as strings.
-callback ensure_schema(connection()) -> ok | {error, term()}.
-callback get_success_history(connection()) -> {ok, [history_row()]} | {error, term()}.
-callback record_migration(connection(), Version :: string(), Name :: string(),
                           Checksum :: string(), Success :: boolean()) ->
    ok | {error, term()}.

%% Locking against concurrent migration runs from several nodes.
%% Drivers without a server-side lock primitive may implement these as no-ops.
-callback lock(connection()) -> ok | {error, term()}.
-callback unlock(connection()) -> ok.

%% Transaction control used for transactional migrations.
-callback begin_tx(connection()) -> ok | {error, term()}.
-callback commit(connection()) -> ok | {error, term()}.
-callback rollback(connection()) -> ok | {error, term()}.

%% Executes the raw SQL of one migration file, possibly containing
%% several statements. Returns {ok, Details} where Details is only used
%% for logging.
-callback run_migration(connection(), binary()) -> {ok, term()} | {error, term()}.

-spec validate_config(config()) -> ok | {error, term()}.
validate_config(Config) ->
    case driver_module(Config) of
        {ok, Driver} ->
            Driver:validate_config(Config);
        {error, Reason} ->
            {error, Reason}
    end.

-spec connect(config()) -> {ok, handle()} | {error, term()}.
connect(Config) ->
    case driver_module(Config) of
        {ok, Driver} ->
            case Driver:connect(Config) of
                {ok, Connection} ->
                    {ok, {Driver, Connection}};
                {error, Reason} ->
                    {error, Reason}
            end;
        {error, Reason} ->
            {error, Reason}
    end.

-spec close(handle()) -> ok.
close({Driver, Connection}) ->
    Driver:close(Connection).

-spec ensure_schema(handle()) -> ok | {error, term()}.
ensure_schema({Driver, Connection}) ->
    Driver:ensure_schema(Connection).

-spec lock(handle()) -> ok | {error, term()}.
lock({Driver, Connection}) ->
    Driver:lock(Connection).

-spec unlock(handle()) -> ok.
unlock({Driver, Connection}) ->
    Driver:unlock(Connection).

-spec begin_tx(handle()) -> ok | {error, term()}.
begin_tx({Driver, Connection}) ->
    Driver:begin_tx(Connection).

-spec commit(handle()) -> ok | {error, term()}.
commit({Driver, Connection}) ->
    Driver:commit(Connection).

-spec rollback(handle()) -> ok | {error, term()}.
rollback({Driver, Connection}) ->
    Driver:rollback(Connection).

-spec run_migration(handle(), binary()) -> {ok, term()} | {error, term()}.
run_migration({Driver, Connection}, Migration) ->
    Driver:run_migration(Connection, Migration).

-spec record_migration(handle(), string(), string(), string(), boolean()) ->
    ok | {error, term()}.
record_migration({Driver, Connection}, Version, Name, Checksum, Success) ->
    Driver:record_migration(Connection, Version, Name, Checksum, Success).

-spec get_success_history(handle()) -> {ok, [history_row()]} | {error, term()}.
get_success_history({Driver, Connection}) ->
    Driver:get_success_history(Connection).

driver_module(Config) ->
    case proplists:get_value(driver, Config, postgres) of
        postgres ->
            {ok, parrot_driver_epgsql};
        mysql ->
            {ok, parrot_driver_mysql};
        mariadb ->
            {ok, parrot_driver_mysql};
        sqlite ->
            {ok, parrot_driver_sqlite};
        Module when is_atom(Module) ->
            custom_driver_module(Module)
    end.

%% A custom driver is any atom besides the built-in names. It must name
%% a loadable module implementing this behaviour; anything else would
%% otherwise fail late with undef.
custom_driver_module(Module) ->
    case code:ensure_loaded(Module) of
        {module, Module} ->
            case erlang:function_exported(Module, connect, 1) of
                true ->
                    {ok, Module};
                false ->
                    {error, {unknown_driver, Module}}
            end;
        {error, _Reason} ->
            {error, {unknown_driver, Module}}
    end.
