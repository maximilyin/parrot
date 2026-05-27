-module(parrot_validation_tests).

-include_lib("eunit/include/eunit.hrl").

invalid_config_missing_host_test() ->
    Config = [{port, 5432}, {user, "u"}, {password, "p"}, {database, "d"}],
    ?assertEqual({error, {missing_config_field, host}}, parrot_validation:validate_config(Config)).

invalid_config_port_not_integer_test() ->
    Config = [
        {host, "localhost"},
        {port, "5432"},
        {user, "u"},
        {password, "p"},
        {database, "d"}
    ],
    ?assertEqual({error, {invalid_config_field, port, integer}}, parrot_validation:validate_config(Config)).

sql_file_without_version_prefix_is_error_test() ->
    Files = ["001_init_upgrade.sql", "001_init_downgrade.sql", "broken.sql"],
    ?assertMatch({error, {invalid_migration_filename, "broken.sql"}}, parrot_validation:validate_files(Files)).

sql_file_with_version_but_invalid_suffix_is_warning_test() ->
    Files = ["001_init_upgrade.sql", "001_init_downgrade.sql", "001_bad name_upgrade.sql"],
    {ok, Warnings} = parrot_validation:validate_files(Files),
    ?assert(lists:member({invalid_migration_suffix, "001_bad name_upgrade.sql"}, Warnings)).

duplicate_first_three_version_digits_is_error_test() ->
    Files = [
        "0010_first_upgrade.sql",
        "0010_first_downgrade.sql",
        "001_second_upgrade.sql",
        "001_second_downgrade.sql"
    ],
    ?assertMatch({error, {duplicate_migration_version, "001", _}}, parrot_validation:validate_files(Files)).

missing_downgrade_is_warning_test() ->
    Files = ["001_init_upgrade.sql"],
    {ok, Warnings} = parrot_validation:validate_files(Files),
    ?assert(
        lists:any(
            fun
                ({missing_downgrade, "001_init_upgrade.sql", "001_init_downgrade.sql"}) ->
                    true;
                (_) ->
                    false
            end,
            Warnings
        )
    ).

checksum_mismatch_for_present_applied_file_is_error_test() ->
    Files = ["001_a_upgrade.sql"],
    History = [{"001", "001_a_upgrade.sql", "deadbeef"}],
    Path = "/tmp/parrot_validation_checksum_test_" ++ integer_to_list(erlang:unique_integer([positive])),
    ok = file:make_dir(Path),
    try
        ok = file:write_file(filename:join(Path, "001_a_upgrade.sql"), <<"SELECT 1;">>),
        ?assertMatch({error, {checksum_mismatch, "001_a_upgrade.sql", _, _}}, parrot_validation:validate_history(Files, History, Path))
    after
        file:delete(filename:join(Path, "001_a_upgrade.sql")),
        file:del_dir(Path)
    end.

missing_historical_applied_file_on_disk_is_not_error_test() ->
    Files = [],
    History = [{"001", "001_gone_upgrade.sql", "any"}],
    Path = "/tmp",
    ?assertEqual(ok, parrot_validation:validate_history(Files, History, Path)).

checksum_match_for_applied_file_is_ok_test() ->
    Path = "/tmp/parrot_validation_checksum_ok_" ++ integer_to_list(erlang:unique_integer([positive])),
    ok = file:make_dir(Path),
    Content = <<"SELECT 1;">>,
    File = "001_a_upgrade.sql",
    try
        ok = file:write_file(filename:join(Path, File), Content),
        Sum = parrot_validation:checksum(Content),
        Files = [File],
        History = [{"001", File, Sum}],
        ?assertEqual(ok, parrot_validation:validate_history(Files, History, Path))
    after
        file:delete(filename:join(Path, File)),
        file:del_dir(Path)
    end.

no_pending_reason_reports_empty_directory_test() ->
    ?assertEqual(no_sql_files, parrot_validation:no_pending_reason([], "")).

no_pending_reason_reports_unrecognized_sql_files_test() ->
    Files = ["001_init.sql", "notes.txt"],
    ?assertEqual(
        {unrecognized_migration_files, [{"001_init.sql", invalid_upgrade_suffix}]},
        parrot_validation:no_pending_reason(Files, "")
    ).

no_pending_reason_reports_already_up_to_date_test() ->
    Files = ["001_init_upgrade.sql", "001_init_downgrade.sql"],
    ?assertEqual(already_up_to_date, parrot_validation:no_pending_reason(Files, "001")).

no_pending_reason_is_undefined_when_pending_exists_test() ->
    Files = ["002_next_upgrade.sql"],
    ?assertEqual(undefined, parrot_validation:no_pending_reason(Files, "001")).

describe_reason_includes_path_for_empty_directory_test() ->
    Message = lists:flatten(
        parrot_validation:describe_reason({no_migrations_applied, no_sql_files, "priv/migrations"})
    ),
    ?assertEqual(true, string:find(Message, "priv/migrations") =/= nomatch),
    ?assertEqual(true, string:find(Message, "no .sql files") =/= nomatch).

describe_reason_explains_invalid_suffix_test() ->
    Message = lists:flatten(
        parrot_validation:describe_reason(
            {unrecognized_migration_files, [{"001_init.sql", invalid_upgrade_suffix}]}
        )
    ),
    ?assertEqual(true, string:find(Message, "001_init.sql") =/= nomatch),
    ?assertEqual(true, string:find(Message, "_upgrade.sql") =/= nomatch).
