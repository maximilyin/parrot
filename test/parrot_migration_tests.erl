-module(parrot_migration_tests).

-include_lib("eunit/include/eunit.hrl").

pending_upgrades_are_sorted_and_filtered_test() ->
    Files = [
        "002_add_accounts_upgrade.sql",
        "001_init_upgrade.sql",
        "001_init_downgrade.sql",
        "002_add_accounts_downgrade.sql",
        "003_add_indexes_downgrade.sql",
        "003_add_indexes_upgrade.sql",
        "notes.txt"
    ],
    ?assertEqual(
        [
            {"002", "002_add_accounts_upgrade.sql"},
            {"003", "003_add_indexes_upgrade.sql"}
        ],
        parrot_validation:pending_upgrades(Files, "001")
    ).

pending_upgrades_keeps_zero_padded_lexicographic_order_test() ->
    Files = [
        "010_ten_upgrade.sql",
        "002_two_upgrade.sql",
        "001_one_upgrade.sql"
    ],
    ?assertEqual(
        [
            {"001", "001_one_upgrade.sql"},
            {"002", "002_two_upgrade.sql"},
            {"010", "010_ten_upgrade.sql"}
        ],
        parrot_validation:pending_upgrades(Files, "")
    ).

missing_downgrades_returns_expected_pairs_test() ->
    Files = [
        "001_init_upgrade.sql",
        "001_init_downgrade.sql",
        "002_accounts_upgrade.sql"
    ],
    ?assertEqual(
        [{"002_accounts_upgrade.sql", "002_accounts_downgrade.sql"}],
        parrot_validation:missing_downgrades(Files)
    ).

current_applied_from_history_removes_downgraded_versions_test() ->
    History = [
        {"001", "001_init_upgrade.sql", "checksum-1"},
        {"002", "002_accounts_upgrade.sql", "checksum-2"},
        {"002", "002_accounts_downgrade.sql", "checksum-3"},
        {"003", "003_indexes_upgrade.sql", "checksum-4"}
    ],
    ?assertEqual(
        [
            {"001", "001_init_upgrade.sql"},
            {"003", "003_indexes_upgrade.sql"}
        ],
        parrot_migration:current_applied_from_history(History)
    ).

downgrade_file_replaces_upgrade_suffix_test() ->
    ?assertEqual(
        "123_init_downgrade.sql",
        parrot_migration:downgrade_file("123_init_upgrade.sql")
    ).

no_transaction_marker_is_detected_test() ->
    ?assert(parrot_migration:no_transaction(<<"-- parrot:no-transaction\nCREATE INDEX CONCURRENTLY idx ON t(id);">>)),
    ?assert(parrot_migration:no_transaction(<<"\n  -- parrot:no-transaction\r\nCREATE INDEX CONCURRENTLY idx ON t(id);">>)),
    ?assertNot(parrot_migration:no_transaction(<<"CREATE TABLE t(id integer);">>)).

checksum_is_stable_sha256_hex_test() ->
    Sql = <<"CREATE TABLE t(id integer);">>,
    Checksum = parrot_validation:checksum(Sql),
    ?assertEqual(64, length(Checksum)),
    ?assertEqual(Checksum, parrot_validation:checksum(Sql)),
    ?assertNotEqual(Checksum, parrot_validation:checksum(<<"CREATE TABLE t(id bigint);">>)).

epgsql_normalize_squery_result_test() ->
    SingleOk = {ok, [], []},
    ?assertEqual({ok, SingleOk}, parrot_driver_epgsql:normalize_squery_result(SingleOk)),
    ?assertEqual({error, boom}, parrot_driver_epgsql:normalize_squery_result({error, boom})),
    OkResults = [{ok, [], []}, {ok, 1}],
    ?assertEqual({ok, OkResults}, parrot_driver_epgsql:normalize_squery_result(OkResults)),
    ?assertEqual(
        {error, first},
        parrot_driver_epgsql:normalize_squery_result(
            [{ok, [], []}, {error, first}, {error, second}, {ok, 1}]
        )
    ).

unknown_driver_is_rejected_by_validate_config_test() ->
    ?assertEqual(
        {error, {unknown_driver, bogus}},
        parrot_driver:validate_config([{driver, bogus}])
    ).

unknown_driver_crashes_migrate_with_validation_failed_test() ->
    ?assertError(
        {validation_failed, {unknown_driver, bogus}},
        parrot:migrate([{driver, bogus}])
    ).

fake_driver_failed_run_records_failure_and_raises_test() ->
    Content = <<"CREATE TABLE t(id integer);">>,
    with_fake_migrate(#{run_migration => boom}, Content, fun(Tab, Config, File) ->
        ?assertError({migration_failed, File, boom}, parrot:migrate(Config)),
        Checksum = parrot_validation:checksum(Content),
        ?assertEqual([{"001", File, Checksum, false}], parrot_fake_driver:history(Tab))
    end).

fake_driver_transactional_call_order_test() ->
    Content = <<"CREATE TABLE t(id integer);">>,
    with_fake_migrate(#{}, Content, fun(Tab, Config, File) ->
        ok = parrot:migrate(Config),
        Calls = parrot_fake_driver:calls(Tab),
        ?assertEqual(
            [begin_tx, run_migration, record_migration, commit],
            transaction_calls(Calls)
        ),
        ?assertEqual(lock, hd(Calls)),
        ?assertEqual(unlock, lists:last(Calls)),
        Checksum = parrot_validation:checksum(Content),
        ?assertEqual([{"001", File, Checksum, true}], parrot_fake_driver:history(Tab))
    end).

fake_driver_record_failure_rolls_back_test() ->
    Content = <<"CREATE TABLE t(id integer);">>,
    with_fake_migrate(#{record_migration => boom}, Content, fun(Tab, Config, File) ->
        ?assertError({migration_failed, File, boom}, parrot:migrate(Config)),
        ?assertEqual(
            [begin_tx, run_migration, record_migration, rollback],
            transaction_calls(parrot_fake_driver:calls(Tab))
        ),
        ?assertEqual([], parrot_fake_driver:history(Tab))
    end).

fake_driver_unlock_called_after_lock_on_failure_test() ->
    Content = <<"CREATE TABLE t(id integer);">>,
    with_fake_migrate(#{run_migration => boom}, Content, fun(Tab, Config, File) ->
        ?assertError({migration_failed, File, boom}, parrot:migrate(Config)),
        Calls = parrot_fake_driver:calls(Tab),
        ?assertEqual(lock, hd(Calls)),
        ?assertEqual(unlock, lists:last(Calls))
    end).

fake_driver_no_transaction_skips_begin_and_commit_test() ->
    Content = <<"-- parrot:no-transaction\nCREATE INDEX CONCURRENTLY idx ON t(id);">>,
    with_fake_migrate(#{}, Content, fun(Tab, Config, File) ->
        ok = parrot:migrate(Config),
        Calls = parrot_fake_driver:calls(Tab),
        ?assertNot(lists:member(begin_tx, Calls)),
        ?assertNot(lists:member(commit, Calls)),
        ?assert(lists:member(run_migration, Calls)),
        Checksum = parrot_validation:checksum(Content),
        ?assertEqual([{"001", File, Checksum, true}], parrot_fake_driver:history(Tab))
    end).

transaction_calls(Calls) ->
    [Call || Call <- Calls,
             lists:member(Call, [begin_tx, run_migration, record_migration, commit, rollback])].

with_fake_migrate(FailMap, MigrationContent, Fun) ->
    Tab = parrot_fake_driver:new(FailMap),
    Dir = temp_migrations_dir(),
    ok = file:make_dir(Dir),
    File = "001_fake_upgrade.sql",
    ok = file:write_file(filename:join(Dir, File), MigrationContent),
    Config = [
        {driver, parrot_fake_driver},
        {fake_state, Tab},
        {migrations_dir, Dir}
    ],
    try
        Fun(Tab, Config, File)
    after
        file:delete(filename:join(Dir, File)),
        file:del_dir(Dir),
        parrot_fake_driver:delete(Tab)
    end.

getenv(Name, Default) ->
    case os:getenv(Name) of
        false ->
            Default;
        Value ->
            Value
    end.

temp_migrations_dir() ->
    filename:join(
        getenv("TMPDIR", "/tmp"),
        "parrot_migrations_test_" ++ integer_to_list(erlang:unique_integer([positive]))
    ).
