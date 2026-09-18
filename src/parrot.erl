-module(parrot).
-export([migrate/1, info/1, rollback/2]).

migrate(Config) ->
    Path = migrations_dir(Config),
    case preflight(Config) of
        {error, Reason} ->
            erlang:error({validation_failed, Reason});
        {ok, Files, _Warnings} ->
            Fun = fun(Connection) ->
                parrot_migration:migrate(Connection, Path, Files)
            end,
            run_or_crash(migration_failed, Config, Fun)
    end.

info(Config) ->
    case preflight(Config) of
        {error, Reason} ->
            {error, Reason};
        {ok, Files, FileWarnings} ->
            case parrot_driver:connect(Config) of
                {ok, Connection} ->
                    try parrot_migration:info(Connection, Files, FileWarnings)
                    after
                        parrot_driver:close(Connection)
                    end;
                {error, Reason} ->
                    {error, Reason}
            end
    end.

rollback(Config, TargetVersion) ->
    Path = migrations_dir(Config),
    case preflight(Config) of
        {error, Reason} ->
            erlang:error({validation_failed, Reason});
        {ok, Files, _Warnings} ->
            Fun = fun(Connection) ->
                parrot_migration:rollback(Connection, Path, TargetVersion, Files)
            end,
            run_or_crash(rollback_failed, Config, Fun)
    end.

%% Shared validation before touching the database: config, migrations
%% directory listing and migration file names.
preflight(Config) ->
    case parrot_driver:validate_config(Config) of
        {error, Reason} ->
            {error, Reason};
        ok ->
            case file:list_dir(migrations_dir(Config)) of
                {error, Reason} ->
                    {error, {migrations_dir, Reason}};
                {ok, Files} ->
                    case parrot_validation:validate_files(Files) of
                        {ok, Warnings} ->
                            {ok, Files, Warnings};
                        {error, Reason} ->
                            {error, Reason}
                    end
            end
    end.

run_or_crash(Tag, Config, Fun) ->
    case parrot_driver:connect(Config) of
        {ok, Connection} ->
            try
                case Fun(Connection) of
                    ok ->
                        ok;
                    {error, Reason} ->
                        log_failure(Tag, Reason),
                        erlang:error({Tag, Reason})
                end
            after
                parrot_driver:close(Connection)
            end;
        {error, Reason} ->
            log_failure(Tag, Reason),
            erlang:error({Tag, Reason})
    end.

log_failure(Tag, Reason) ->
    error_logger:error_msg("parrot: ~s failed: ~s", [Tag, describe_failure(Reason)]).

describe_failure({no_migrations_applied, Reason, Path}) ->
    lists:flatten(parrot_validation:describe_reason({no_migrations_applied, Reason, Path}));
describe_failure(Reason) ->
    lists:flatten(parrot_validation:describe_reason(Reason)).

migrations_dir(Config) ->
    proplists:get_value(migrations_dir, Config, "priv/migrations").
