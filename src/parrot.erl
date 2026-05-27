-module(parrot).
-export([migrate/1, info/1, rollback/2]).

migrate(Config) ->
    Path = migrations_dir(Config),
    case parrot_validation:validate_config(Config) of
        {error, Reason} ->
            erlang:error({validation_failed, Reason});
        ok ->
            case file:list_dir(Path) of
                {error, Reason} ->
                    erlang:error({validation_failed, {migrations_dir, Reason}});
                {ok, Files} ->
                    case parrot_validation:validate_files(Files) of
                        {error, Reason} ->
                            erlang:error({validation_failed, Reason});
                        {ok, _Warnings} ->
                            Fun = fun(Connection) ->
                                parrot_migration:migrate(Connection, Path, Files)
                            end,
                            run_or_crash(migration_failed, Config, Fun)
                    end
            end
    end.

info(Config) ->
    Path = migrations_dir(Config),
    case parrot_validation:validate_config(Config) of
        {error, Reason} ->
            {error, Reason};
        ok ->
            case file:list_dir(Path) of
                {error, Reason} ->
                    {error, {migrations_dir, Reason}};
                {ok, Files} ->
                    case parrot_validation:validate_files(Files) of
                        {error, Reason} ->
                            {error, Reason};
                        {ok, FileWarnings} ->
                            case parrot_driver:get_connection(Config) of
                                {ok, Connection} ->
                                    try parrot_migration:info(Connection, Files, FileWarnings)
                                    after
                                        close_connection(Connection)
                                    end;
                                {error, Reason} ->
                                    {error, Reason}
                            end
                    end
            end
    end.

rollback(Config, TargetVersion) ->
    Path = migrations_dir(Config),
    case parrot_validation:validate_config(Config) of
        {error, Reason} ->
            erlang:error({validation_failed, Reason});
        ok ->
            case file:list_dir(Path) of
                {error, Reason} ->
                    erlang:error({validation_failed, {migrations_dir, Reason}});
                {ok, Files} ->
                    case parrot_validation:validate_files(Files) of
                        {error, Reason} ->
                            erlang:error({validation_failed, Reason});
                        {ok, _Warnings} ->
                            Fun = fun(Connection) ->
                                parrot_migration:rollback(Connection, Path, TargetVersion, Files)
                            end,
                            run_or_crash(rollback_failed, Config, Fun)
                    end
            end
    end.

run_or_crash(Tag, Config, Fun) ->
    case parrot_driver:get_connection(Config) of
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
                close_connection(Connection)
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

close_connection(Connection) ->
    unlink(Connection),
    catch epgsql:close(Connection),
    receive
        {'EXIT', Connection, _Reason} ->
            ok
    after 0 ->
        ok
    end,
    ok.

migrations_dir(Config) ->
    proplists:get_value(migrations_dir, Config, "priv/migrations").
