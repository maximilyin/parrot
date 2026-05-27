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

integration_migrate_creates_schema_and_applies_sql_test_() ->
    case os:getenv("PARROT_TEST_DOCKER") of
        "1" ->
            {setup,
             fun setup_pg_migration/0,
             fun cleanup_pg_migration/1,
             fun(State) ->
                 ?_test(assert_pg_migration(State))
             end};
        _ ->
            []
    end.

setup_pg_migration() ->
    PreviousTrapExit = process_flag(trap_exit, true),
    Container = docker_container_name(),
    Port = docker_host_port(),
    try
        start_postgres_container(Container, Port),
        Config = pg_config(Port),
        wait_for_postgres(Container, 30),
        Path = temp_migrations_dir(),
        ok = file:make_dir(Path),
        ok = file:write_file(
            filename:join(Path, "001_create_widget_upgrade.sql"),
            <<
                "CREATE TABLE parrot_test_widget(id integer PRIMARY KEY, name text);\n",
                "INSERT INTO parrot_test_widget(id, name) VALUES (1, 'created by parrot');\n"
            >>
        ),
        ok = file:write_file(
            filename:join(Path, "001_create_widget_downgrade.sql"),
            <<"DROP TABLE parrot_test_widget;\n">>
        ),
        TestConfig = [{migrations_dir, Path} | Config],
        {TestConfig, Path, Container, PreviousTrapExit}
    catch
        Class:Reason:Stacktrace ->
            remove_postgres_container(Container),
            process_flag(trap_exit, PreviousTrapExit),
            erlang:raise(Class, Reason, Stacktrace)
    end.

cleanup_pg_migration({_Config, Path, Container, PreviousTrapExit}) ->
    file:delete(filename:join(Path, "001_create_widget_upgrade.sql")),
    file:delete(filename:join(Path, "001_create_widget_downgrade.sql")),
    file:del_dir(Path),
    remove_postgres_container(Container),
    flush_exit_messages(),
    process_flag(trap_exit, PreviousTrapExit),
    ok.

assert_pg_migration({Config, _Path, _Container, _PreviousTrapExit}) ->
    ok = parrot:migrate(Config),
    {ok, Connection} = parrot_driver:get_connection(Config),
    try
        ?assertEqual(1, select_count(Connection, <<"SELECT count(*) FROM migrations">>)),
        ?assertEqual(
            1,
            select_count(
                Connection,
                <<"SELECT count(*) FROM migrations ",
                  "WHERE version = '001' ",
                  "AND name = '001_create_widget_upgrade.sql' ",
                  "AND success = TRUE">>
            )
        ),
        ?assertEqual(
            1,
            select_count(
                Connection,
                <<"SELECT count(*) FROM parrot_test_widget ",
                  "WHERE id = 1 AND name = 'created by parrot'">>
            )
        )
    after
        close_connection(Connection)
    end.

select_count(Connection, Sql) ->
    {ok, _, [{Count}]} = epgsql:squery(Connection, Sql),
    Count.

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

pg_config(Port) ->
    [
        {host, "localhost"},
        {port, Port},
        {user, "postgres"},
        {password, "postgres"},
        {database, "postgres"}
    ].

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

docker_container_name() ->
    "parrot_pg_test_" ++ integer_to_list(erlang:unique_integer([positive])).

docker_host_port() ->
    20000 + erlang:unique_integer([positive]) rem 20000.

start_postgres_container(Container, Port) ->
    Command = lists:flatten(io_lib:format(
        "docker run -d --name ~s "
        "-e POSTGRES_PASSWORD=postgres "
        "-e POSTGRES_DB=postgres "
        "-p 127.0.0.1:~B:5432 "
        "postgres:16-alpine",
        [Container, Port]
    )),
    Output = string:trim(os:cmd(Command)),
    case docker_container_running(Container) of
        true ->
            ok;
        false ->
            erlang:error({docker_start_failed, Output})
    end.

docker_container_running(Container) ->
    "true" =:= string:trim(os:cmd("docker inspect -f '{{.State.Running}}' " ++ Container)).

remove_postgres_container(Container) ->
    os:cmd("docker rm -f " ++ Container),
    flush_exit_messages(),
    ok.

flush_exit_messages() ->
    receive
        {'EXIT', _Pid, _Reason} ->
            flush_exit_messages()
    after 0 ->
        ok
    end.

wait_for_postgres(_Container, 0) ->
    erlang:error(postgres_container_not_ready);
wait_for_postgres(Container, AttemptsLeft) ->
    Command = "docker exec " ++ Container ++ " pg_isready -U postgres -d postgres",
    case string:str(os:cmd(Command), "accepting connections") of
        0 ->
            timer:sleep(1000),
            wait_for_postgres(Container, AttemptsLeft - 1);
        _ ->
            timer:sleep(500),
            ok
    end.
