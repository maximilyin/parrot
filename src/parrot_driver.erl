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
    lock/2,
    unlock/2,
    lock_options/1,
    log_lock_wait/1,
    begin_tx/1,
    commit/1,
    rollback/1,
    run_migration/2,
    record_migration/5,
    get_success_history/1
]).

-define(DEFAULT_LOCK_KEY, <<"parrot:migrations">>).

-type config() :: [{atom(), term()}].
-type connection() :: term().
-type handle() :: {module(), connection()}.
-type history_row() :: {Version :: string(), Name :: string(), Checksum :: string()}.
%% `timeout' is in milliseconds; 0 means try once and fail immediately.
-type lock_options() :: #{key := binary(), timeout := timeout()}.

-export_type([config/0, connection/0, handle/0, history_row/0, lock_options/0]).

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
%% lock/2 and unlock/2 receive the configured lock_key and lock_timeout;
%% they are only used when both are exported. Otherwise the /1 variants
%% are used and validate_config/1 rejects those options with
%% {unsupported_config_field, Field, Driver}.
%% A lock/2 that has to wait for the lock should call log_lock_wait/1
%% once before blocking, and return {error, {lock_timeout, Key, Timeout}}
%% when the timeout expires.
-callback lock(connection()) -> ok | {error, term()}.
-callback unlock(connection()) -> ok.
-callback lock(connection(), lock_options()) -> ok | {error, term()}.
-callback unlock(connection(), lock_options()) -> ok.

-optional_callbacks([lock/2, unlock/2]).

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
            case parrot_validation:validate_lock_options(Config) of
                ok ->
                    case Driver:validate_config(Config) of
                        ok ->
                            validate_lock_support(Driver, Config);
                        {error, Reason} ->
                            {error, Reason}
                    end;
                {error, Reason} ->
                    {error, Reason}
            end;
        {error, Reason} ->
            {error, Reason}
    end.

%% Expects a config already accepted by validate_config/1.
-spec lock_options(config()) -> lock_options().
lock_options(Config) ->
    Key = unicode:characters_to_binary(proplists:get_value(lock_key, Config, ?DEFAULT_LOCK_KEY)),
    #{key => Key, timeout => proplists:get_value(lock_timeout, Config, infinity)}.

-spec log_lock_wait(lock_options()) -> ok.
log_lock_wait(#{key := Key, timeout := Timeout}) ->
    error_logger:warning_msg(
        "parrot: waiting for migration lock ~ts (~s); another node may be running migrations",
        [Key, describe_lock_timeout(Timeout)]
    ).

describe_lock_timeout(infinity) ->
    "no timeout";
describe_lock_timeout(Timeout) ->
    io_lib:format("timeout: ~p ms", [Timeout]).

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

-spec lock(handle(), lock_options()) -> ok | {error, term()}.
lock({Driver, Connection}, LockOptions) ->
    case supports_lock_options(Driver) of
        true ->
            Driver:lock(Connection, LockOptions);
        false ->
            Driver:lock(Connection)
    end.

-spec unlock(handle(), lock_options()) -> ok.
unlock({Driver, Connection}, LockOptions) ->
    case supports_lock_options(Driver) of
        true ->
            Driver:unlock(Connection, LockOptions);
        false ->
            Driver:unlock(Connection)
    end.

%% lock/2 and unlock/2 are only used as a pair so that a lock is always
%% released through the same arity that took it. The driver module is
%% already loaded by validate_config/1 or connect/1, so
%% erlang:function_exported/3 is reliable here.
supports_lock_options(Driver) ->
    erlang:function_exported(Driver, lock, 2) andalso erlang:function_exported(Driver, unlock, 2).

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

%% Drivers without both lock/2 and unlock/2 cannot honour lock_key /
%% lock_timeout; reject them instead of silently using the default lock.
validate_lock_support(Driver, Config) ->
    case supports_lock_options(Driver) of
        true ->
            ok;
        false ->
            case [Field || Field <- [lock_key, lock_timeout], proplists:is_defined(Field, Config)] of
                [] ->
                    ok;
                [Field | _] ->
                    {error, {unsupported_config_field, Field, Driver}}
            end
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
