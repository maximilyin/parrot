-module(parrot_migration).
-export([migrate/3, info/3, rollback/4]).

-ifdef(TEST).
-export([current_applied_from_history/1, downgrade_file/1, no_transaction/1]).
-endif.

%% Connection is a parrot_driver:handle(); all database access goes
%% through the parrot_driver dispatch module.

migrate(Connection, Path, Files) ->
    with_lock(Connection, fun() ->
        case parrot_driver:ensure_schema(Connection) of
            ok ->
                validate_and_apply_migrations(Connection, Path, Files);
            {error, Reason} ->
                {error, Reason}
        end
    end).

info(Connection, Files, FileWarnings) ->
    case parrot_driver:ensure_schema(Connection) of
        ok ->
            get_info(Connection, Files, FileWarnings);
        {error, Reason} ->
            {error, Reason}
    end.

rollback(Connection, Path, TargetVersion, Files) ->
    with_lock(Connection, fun() ->
        case parrot_driver:ensure_schema(Connection) of
            ok ->
                rollback_migrations(Connection, Path, normalize_version(TargetVersion), Files);
            {error, Reason} ->
                {error, Reason}
        end
    end).

validate_and_apply_migrations(Connection, Path, Files) ->
    case validate_history_on_disk(Connection, Path, Files) of
        ok ->
            apply_migrations(Connection, Path, Files);
        {error, Reason} ->
            {error, Reason}
    end.

apply_migrations(Connection, Path, Files) ->
    case get_current_version(Connection) of
        {ok, CurrentVersion} ->
            Migrations = parrot_validation:pending_upgrades(Files, CurrentVersion),
            case Migrations of
                [_ | _] ->
                    apply_pending_migrations(Connection, Path, Migrations);
                [] ->
                    report_no_pending_migrations(Path, Files, CurrentVersion)
            end;
        {error, Reason} ->
            {error, Reason}
    end.

report_no_pending_migrations(Path, Files, CurrentVersion) ->
    case parrot_validation:no_pending_reason(Files, CurrentVersion) of
        undefined ->
            ok;
        already_up_to_date ->
            ok;
        Reason ->
            {error, {no_migrations_applied, Reason, Path}}
    end.

migration_failure_message(Reason) ->
    lists:flatten(["migration failed: ", parrot_validation:describe_reason(Reason)]).

rollback_migrations(Connection, Path, TargetVersion, Files) ->
    case validate_history_on_disk(Connection, Path, Files) of
        ok ->
            case get_current_applied_upgrades(Connection) of
                {ok, Applied} ->
                    Rollbacks = [{Version, downgrade_file(File)} || {Version, File} <- lists:reverse(Applied),
                                                                  Version > TargetVersion],
                    apply_pending_migrations(Connection, Path, Rollbacks);
                {error, Reason} ->
                    {error, Reason}
            end;
        {error, Reason} ->
            {error, Reason}
    end.

validate_history_on_disk(Connection, Path, Files) ->
    case parrot_driver:get_success_history(Connection) of
        {ok, History} ->
            parrot_validation:validate_history(Files, History, Path);
        {error, Reason} ->
            {error, Reason}
    end.

get_info(Connection, Files, FileWarnings) ->
    case get_current_version(Connection) of
        {ok, CurrentVersion} ->
            case parrot_driver:get_success_history(Connection) of
                {ok, History} ->
                    {ok, [
                        {current_version, CurrentVersion},
                        {applied, current_applied_from_history(History)},
                        {pending, parrot_validation:pending_upgrades(Files, CurrentVersion)},
                        {missing_downgrades, parrot_validation:missing_downgrades(Files)},
                        {warnings, FileWarnings}
                    ]};
                {error, Reason} ->
                    {error, Reason}
            end;
        {error, Reason} ->
            {error, Reason}
    end.

apply_pending_migrations(_Connection, _Path, []) ->
    ok;
apply_pending_migrations(Connection, Path, [{Version, File} | Rest]) ->
    case file:read_file(filename:join(Path, File)) of
        {ok, Migration} ->
            case apply_migration(Connection, Version, File, Migration) of
                ok ->
                    apply_pending_migrations(Connection, Path, Rest);
                {error, Reason} ->
                    erlang:error({migration_failed, File, Reason})
            end;
        {error, Reason} ->
            error_logger:error_msg("parrot: ~s", [migration_failure_message(Reason)]),
            erlang:error({migration_failed, File, Reason})
    end.

get_current_version(Connection) ->
    case get_current_applied_upgrades(Connection) of
        {ok, []} ->
            {ok, ""};
        {ok, Applied} ->
            {ok, lists:max([Version || {Version, _File} <- Applied])};
        {error, Reason} ->
            {error, Reason}
    end.

get_current_applied_upgrades(Connection) ->
    case parrot_driver:get_success_history(Connection) of
        {ok, History} ->
            {ok, current_applied_from_history(History)};
        {error, Reason} ->
            {error, Reason}
    end.

current_applied_from_history(History) ->
    lists:sort(lists:foldl(fun current_applied_from_row/2, [], History)).

current_applied_from_row({Version, File, _Checksum}, Applied) ->
    case {is_upgrade_file(File), is_downgrade_file(File)} of
        {true, false} ->
            lists:keystore(Version, 1, Applied, {Version, File});
        {false, true} ->
            lists:keydelete(Version, 1, Applied);
        _ ->
            Applied
    end.

downgrade_file(UpgradeFile) ->
    parrot_validation:upgrade_to_downgrade_filename(UpgradeFile).

normalize_version(Version) when is_binary(Version) ->
    binary_to_list(Version);
normalize_version(Version) ->
    Version.

is_upgrade_file(File) ->
    lists:suffix("_upgrade.sql", File).

is_downgrade_file(File) ->
    lists:suffix("_downgrade.sql", File).

apply_migration(Connection, Version, File, Migration) ->
    Checksum = parrot_validation:checksum(Migration),
    case no_transaction(Migration) of
        true ->
            apply_migration_without_transaction(Connection, Version, File, Migration, Checksum);
        false ->
            apply_migration_in_transaction(Connection, Version, File, Migration, Checksum)
    end.

apply_migration_in_transaction(Connection, Version, File, Migration, Checksum) ->
    case parrot_driver:begin_tx(Connection) of
        ok ->
            case parrot_driver:run_migration(Connection, Migration) of
                {error, Reason} ->
                    _ = parrot_driver:rollback(Connection),
                    error_logger:error_msg("parrot: ~s", [migration_failure_message(Reason)]),
                    _ = parrot_driver:record_migration(Connection, Version, File, Checksum, false),
                    {error, Reason};
                {ok, Result} ->
                    ok = error_logger:info_msg("Migration was completed with result: ~p", [Result]),
                    case parrot_driver:record_migration(Connection, Version, File, Checksum, true) of
                        ok ->
                            parrot_driver:commit(Connection);
                        {error, Reason} ->
                            _ = parrot_driver:rollback(Connection),
                            {error, Reason}
                    end
            end;
        {error, Reason} ->
            {error, Reason}
    end.

apply_migration_without_transaction(Connection, Version, File, Migration, Checksum) ->
    case parrot_driver:run_migration(Connection, Migration) of
        {error, Reason} ->
            error_logger:error_msg("parrot: ~s", [migration_failure_message(Reason)]),
            _ = parrot_driver:record_migration(Connection, Version, File, Checksum, false),
            {error, Reason};
        {ok, Result} ->
            ok = error_logger:info_msg("Migration was completed with result: ~p", [Result]),
            parrot_driver:record_migration(Connection, Version, File, Checksum, true)
    end.

no_transaction(Migration) ->
    case re:run(Migration, <<"^\\s*--\\s*parrot:no-transaction\\s*(\\r?\\n|$)">>) of
        {match, _} ->
            true;
        nomatch ->
            false
    end.

with_lock(Connection, Fun) ->
    case parrot_driver:lock(Connection) of
        ok ->
            try Fun()
            after
                parrot_driver:unlock(Connection)
            end;
        {error, Reason} ->
            {error, Reason}
    end.
