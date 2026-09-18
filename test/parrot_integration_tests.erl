-module(parrot_integration_tests).

%% Integration tests that run real migrations against PostgreSQL,
%% MySQL/MariaDB and SQLite.
%%
%% SQLite scenarios always run: they only need a temporary database file.
%% PostgreSQL and MySQL scenarios run only when the corresponding
%% PARROT_TEST_PG_HOST / PARROT_TEST_MYSQL_HOST environment variable is
%% set; scripts/integration-tests.sh starts the database containers and
%% exports these variables.
%%
%% Every scenario gets a fresh database (CREATE DATABASE with a unique
%% name, or a unique temp file for SQLite) and a unique temporary
%% migrations directory; both are removed in cleanup even on failure.

-include_lib("eunit/include/eunit.hrl").

%% Test generators.

sqlite_integration_test_() ->
    scenarios(sqlite_spec()).

pg_integration_test_() ->
    case os:getenv("PARROT_TEST_PG_HOST") of
        false ->
            [];
        Host ->
            Spec = pg_spec(Host),
            scenarios(Spec) ++ extra_scenarios(Spec)
    end.

mysql_integration_test_() ->
    case os:getenv("PARROT_TEST_MYSQL_HOST") of
        false ->
            [];
        Host ->
            Spec = mysql_spec(Host),
            scenarios(Spec) ++ extra_scenarios(Spec)
    end.

%% Database specs.

sqlite_spec() ->
    #{kind => sqlite}.

pg_spec(Host) ->
    #{kind => pg,
      host => Host,
      port => env_integer("PARROT_TEST_PG_PORT", 5432),
      user => "postgres",
      password => "postgres"}.

mysql_spec(Host) ->
    #{kind => mysql,
      host => Host,
      port => env_integer("PARROT_TEST_MYSQL_PORT", 3306),
      user => "root",
      password => env_string("PARROT_TEST_MYSQL_PASSWORD", "parrot")}.

%% Scenario matrix shared by all databases.

scenarios(Spec) ->
    [
        happy_path_scenario(Spec),
        multi_statement_scenario(Spec),
        failing_transactional_scenario(Spec),
        failing_no_transaction_scenario(Spec),
        checksum_mismatch_scenario(Spec),
        sequential_upgrade_and_rollback_scenario(Spec),
        missing_downgrade_rollback_scenario(Spec)
    ].

extra_scenarios(Spec) ->
    [concurrent_migrators_scenario(Spec)].

happy_path_scenario(Spec) ->
    File = "001_widgets_upgrade.sql",
    Files = [
        {File, <<"CREATE TABLE parrot_it_widgets (id INTEGER PRIMARY KEY, name VARCHAR(64));\n">>},
        {"001_widgets_downgrade.sql", <<"DROP TABLE parrot_it_widgets;\n">>}
    ],
    scenario(Spec, "happy path: migrate, info, re-migrate, rollback", Files, fun(Config) ->
        ok = parrot:migrate(Config),
        ?assertEqual(1, table_exists(Spec, Config, "parrot_it_widgets")),
        ?assertEqual(1, count(Spec, Config, "SELECT count(*) FROM migrations")),
        {ok, Info} = parrot:info(Config),
        ?assertEqual("001", proplists:get_value(current_version, Info)),
        ?assertEqual([{"001", File}], proplists:get_value(applied, Info)),
        ?assertEqual([], proplists:get_value(pending, Info)),
        %% Re-running is idempotent: no new history rows.
        ok = parrot:migrate(Config),
        ?assertEqual(1, count(Spec, Config, "SELECT count(*) FROM migrations")),
        %% Rollback to "000" drops the table and appends a downgrade row.
        ok = parrot:rollback(Config, "000"),
        ?assertEqual(0, table_exists(Spec, Config, "parrot_it_widgets")),
        ?assertEqual(2, count(Spec, Config, "SELECT count(*) FROM migrations")),
        {ok, RolledBack} = parrot:info(Config),
        ?assertEqual("", proplists:get_value(current_version, RolledBack)),
        ?assertEqual([], proplists:get_value(applied, RolledBack)),
        ?assertEqual([{"001", File}], proplists:get_value(pending, RolledBack))
    end).

multi_statement_scenario(Spec) ->
    Files = [
        {"001_multi_upgrade.sql", <<
            "CREATE TABLE parrot_it_multi (id INTEGER PRIMARY KEY, name VARCHAR(64));\n"
            "INSERT INTO parrot_it_multi (id, name) VALUES (1, 'one');\n"
            "UPDATE parrot_it_multi SET name = 'uno' WHERE id = 1;\n"
        >>}
    ],
    scenario(Spec, "multi-statement migration applies all statements", Files, fun(Config) ->
        ok = parrot:migrate(Config),
        ?assertEqual(
            1,
            count(Spec, Config, "SELECT count(*) FROM parrot_it_multi WHERE id = 1 AND name = 'uno'")
        ),
        ?assertEqual(1, count(Spec, Config, "SELECT count(*) FROM migrations"))
    end).

failing_transactional_scenario(Spec) ->
    File = "001_txfail_upgrade.sql",
    Files = [
        {File, <<
            "CREATE TABLE parrot_it_txfail (id INTEGER PRIMARY KEY);\n"
            "INSERT INTO nonexistent_table_xyz (id) VALUES (1);\n"
        >>}
    ],
    scenario(Spec, "failing transactional migration records failure", Files, fun(Config) ->
        ?assertError({migration_failed, File, _}, parrot:migrate(Config)),
        ?assertEqual(1, count(Spec, Config, failed_history_sql(Spec))),
        case maps:get(kind, Spec) of
            mysql ->
                %% MySQL DDL statements auto-commit, so the CREATE TABLE
                %% before the failing statement cannot be rolled back;
                %% only the failure row and the raised error apply.
                ?assertEqual(1, table_exists(Spec, Config, "parrot_it_txfail"));
            _ ->
                ?assertEqual(0, table_exists(Spec, Config, "parrot_it_txfail"))
        end
    end).

failing_no_transaction_scenario(Spec) ->
    File = "001_notx_upgrade.sql",
    Files = [{File, no_transaction_migration(Spec)}],
    scenario(Spec, "no-transaction failure keeps applied statements", Files, fun(Config) ->
        ?assertError({migration_failed, File, _}, parrot:migrate(Config)),
        ?assertEqual(1, table_exists(Spec, Config, "parrot_it_notx")),
        ?assertEqual(1, count(Spec, Config, failed_history_sql(Spec)))
    end).

%% PostgreSQL executes a multi-statement simple query in an implicit
%% transaction, so without the explicit COMMIT the CREATE TABLE would be
%% rolled back together with the failing INSERT even outside parrot's
%% transaction handling. The no-transaction marker exists precisely so
%% migration authors can control transaction boundaries themselves.
no_transaction_migration(#{kind := pg}) ->
    <<
        "-- parrot:no-transaction\n"
        "CREATE TABLE parrot_it_notx (id INTEGER PRIMARY KEY);\n"
        "COMMIT;\n"
        "INSERT INTO nonexistent_table_xyz (id) VALUES (1);\n"
    >>;
no_transaction_migration(_Spec) ->
    <<
        "-- parrot:no-transaction\n"
        "CREATE TABLE parrot_it_notx (id INTEGER PRIMARY KEY);\n"
        "INSERT INTO nonexistent_table_xyz (id) VALUES (1);\n"
    >>.

checksum_mismatch_scenario(Spec) ->
    File = "001_checksum_upgrade.sql",
    Files = [{File, <<"CREATE TABLE parrot_it_checksum (id INTEGER PRIMARY KEY);\n">>}],
    scenario(Spec, "checksum mismatch of applied migration fails", Files, fun(Config) ->
        ok = parrot:migrate(Config),
        Dir = proplists:get_value(migrations_dir, Config),
        Mutated = <<"CREATE TABLE parrot_it_checksum (id INTEGER PRIMARY KEY, name VARCHAR(64));\n">>,
        ok = file:write_file(filename:join(Dir, File), Mutated),
        ?assertError(
            {migration_failed, {checksum_mismatch, File, _, _}},
            parrot:migrate(Config)
        )
    end).

sequential_upgrade_and_rollback_scenario(Spec) ->
    File1 = "001_seq_widgets_upgrade.sql",
    File2 = "002_seq_gadgets_upgrade.sql",
    Files = [
        {File1, <<"CREATE TABLE parrot_it_seq_w (id INTEGER PRIMARY KEY, name VARCHAR(64));\n">>},
        {"001_seq_widgets_downgrade.sql", <<"DROP TABLE parrot_it_seq_w;\n">>},
        {File2, <<"CREATE TABLE parrot_it_seq_g (id INTEGER PRIMARY KEY, name VARCHAR(64));\n">>},
        {"002_seq_gadgets_downgrade.sql", <<"DROP TABLE parrot_it_seq_g;\n">>}
    ],
    scenario(Spec, "sequential upgrade then rollback to 001", Files, fun(Config) ->
        {ok, Before} = parrot:info(Config),
        ?assertEqual("", proplists:get_value(current_version, Before)),
        ?assertEqual([], proplists:get_value(applied, Before)),
        ?assertEqual(
            [{"001", File1}, {"002", File2}],
            proplists:get_value(pending, Before)
        ),
        ?assertEqual(1, table_exists(Spec, Config, "migrations")),
        ok = parrot:migrate(Config),
        ?assertEqual(1, table_exists(Spec, Config, "parrot_it_seq_w")),
        ?assertEqual(1, table_exists(Spec, Config, "parrot_it_seq_g")),
        ?assertEqual(2, count(Spec, Config, "SELECT count(*) FROM migrations")),
        {ok, Migrated} = parrot:info(Config),
        ?assertEqual("002", proplists:get_value(current_version, Migrated)),
        ?assertEqual(
            [{"001", File1}, {"002", File2}],
            proplists:get_value(applied, Migrated)
        ),
        ?assertEqual([], proplists:get_value(pending, Migrated)),
        ok = parrot:migrate(Config),
        ?assertEqual(2, count(Spec, Config, "SELECT count(*) FROM migrations")),
        %% Do not migrate again after this rollback: a unique partial
        %% index on PostgreSQL/SQLite rejects re-applying the same
        %% successful upgrade name.
        ok = parrot:rollback(Config, "001"),
        ?assertEqual(0, table_exists(Spec, Config, "parrot_it_seq_g")),
        ?assertEqual(1, table_exists(Spec, Config, "parrot_it_seq_w")),
        ?assertEqual(3, count(Spec, Config, "SELECT count(*) FROM migrations")),
        {ok, RolledBack} = parrot:info(Config),
        ?assertEqual("001", proplists:get_value(current_version, RolledBack)),
        ?assertEqual([{"001", File1}], proplists:get_value(applied, RolledBack)),
        ?assertEqual([{"002", File2}], proplists:get_value(pending, RolledBack))
    end).

missing_downgrade_rollback_scenario(Spec) ->
    Upgrade = "001_nodown_upgrade.sql",
    Downgrade = "001_nodown_downgrade.sql",
    Files = [{Upgrade, <<"CREATE TABLE parrot_it_nodown (id INTEGER PRIMARY KEY);\n">>}],
    scenario(Spec, "rollback without a downgrade file fails", Files, fun(Config) ->
        ok = parrot:migrate(Config),
        {ok, Info} = parrot:info(Config),
        ?assertEqual(
            [{Upgrade, Downgrade}],
            proplists:get_value(missing_downgrades, Info)
        ),
        %% apply_pending_migrations raises {migration_failed, File, Reason}
        %% via erlang:error/1 rather than returning {error, ...} for
        %% run_or_crash to wrap as {rollback_failed, ...}.
        ?assertError(
            {migration_failed, Downgrade, enoent},
            parrot:rollback(Config, "000")
        ),
        ?assertEqual(1, table_exists(Spec, Config, "parrot_it_nodown")),
        ?assertEqual(1, count(Spec, Config, successful_history_sql(Spec)))
    end).

concurrent_migrators_scenario(Spec) ->
    Files = [{"001_lock_upgrade.sql", lock_migration_sql(Spec)}],
    scenario(Spec, "concurrent migrators serialize on the migration lock", Files, fun(Config) ->
        Parent = self(),
        Start = fun() ->
            spawn_link(fun() -> Parent ! {self(), parrot:migrate(Config)} end)
        end,
        Pid1 = Start(),
        Pid2 = Start(),
        Results = [wait_migrator(Pid1, 20000), wait_migrator(Pid2, 20000)],
        ?assertEqual([ok, ok], lists:sort(Results)),
        ?assertEqual(1, count(Spec, Config, successful_history_sql(Spec))),
        ?assertEqual(1, table_exists(Spec, Config, "parrot_it_lock"))
    end).

lock_migration_sql(#{kind := pg}) ->
    <<"SELECT pg_sleep(1);\nCREATE TABLE parrot_it_lock (id INTEGER PRIMARY KEY);\n">>;
lock_migration_sql(#{kind := mysql}) ->
    <<"SELECT SLEEP(1);\nCREATE TABLE parrot_it_lock (id INTEGER PRIMARY KEY);\n">>.

wait_migrator(Pid, Timeout) ->
    receive
        {Pid, Result} ->
            Result;
        {'EXIT', Pid, Reason} ->
            {'EXIT', Reason}
    after Timeout ->
        erlang:error({migrator_timeout, Pid})
    end.

%% Scenario runner.

scenario(Spec, Name, MigrationFiles, Fun) ->
    Title = lists:flatten(io_lib:format("~s: ~s", [spec_label(Spec), Name])),
    {Title, {timeout, 60, fun() -> with_scenario(Spec, MigrationFiles, Fun) end}}.

with_scenario(Spec, MigrationFiles, Fun) ->
    %% epgsql and mysql-otp link their connection processes to the
    %% caller; trap exits for the duration of the scenario and drain
    %% any leftover 'EXIT' messages before restoring the flag.
    PreviousTrapExit = process_flag(trap_exit, true),
    try
        Dir = temp_migrations_dir(),
        ok = file:make_dir(Dir),
        try
            write_migration_files(Dir, MigrationFiles),
            Db = create_database(Spec),
            try
                Fun(scenario_config(Spec, Db, Dir))
            after
                drop_database(Spec, Db)
            end
        after
            delete_dir(Dir)
        end
    after
        drain_exit_messages(),
        process_flag(trap_exit, PreviousTrapExit)
    end.

%% Per-database plumbing: fresh database, parrot config, native queries.

create_database(#{kind := sqlite}) ->
    filename:join(tmp_dir(), unique_name("parrot_it") ++ ".db");
create_database(#{kind := pg} = Spec) ->
    Db = unique_name("parrot_it"),
    ok = with_pg_connection(Spec, "postgres", fun(Connection) ->
        exec_pg(Connection, "CREATE DATABASE " ++ Db)
    end),
    Db;
create_database(#{kind := mysql} = Spec) ->
    Db = unique_name("parrot_it"),
    ok = with_mysql_connection(Spec, undefined, fun(Connection) ->
        ok = mysql:query(Connection, "CREATE DATABASE " ++ Db)
    end),
    Db.

drop_database(#{kind := sqlite}, Db) ->
    lists:foreach(
        fun(Suffix) -> file:delete(Db ++ Suffix) end,
        ["", "-journal", "-wal", "-shm"]
    );
drop_database(#{kind := pg} = Spec, Db) ->
    with_pg_connection(Spec, "postgres", fun(Connection) ->
        exec_pg(Connection, "DROP DATABASE " ++ Db ++ " WITH (FORCE)")
    end);
drop_database(#{kind := mysql} = Spec, Db) ->
    with_mysql_connection(Spec, undefined, fun(Connection) ->
        ok = mysql:query(Connection, "DROP DATABASE " ++ Db)
    end).

scenario_config(#{kind := sqlite}, Db, Dir) ->
    [{driver, sqlite}, {database, Db}, {migrations_dir, Dir}];
scenario_config(#{kind := pg} = Spec, Db, Dir) ->
    [{driver, postgres}, {database, Db}, {migrations_dir, Dir} | server_options(Spec)];
scenario_config(#{kind := mysql} = Spec, Db, Dir) ->
    [{driver, mysql}, {database, Db}, {migrations_dir, Dir} | server_options(Spec)].

server_options(#{host := Host, port := Port, user := User, password := Password}) ->
    [{host, Host}, {port, Port}, {user, User}, {password, Password}].

%% Runs a scalar "SELECT count(*) ..." against the scenario database
%% using the database's native client and returns the count.
count(#{kind := sqlite}, Config, Sql) ->
    Db = proplists:get_value(database, Config),
    {ok, Connection} = esqlite3:open(Db),
    try
        [[N]] = esqlite3:q(Connection, Sql),
        N
    after
        esqlite3:close(Connection)
    end;
count(#{kind := pg} = Spec, Config, Sql) ->
    with_pg_connection(Spec, proplists:get_value(database, Config), fun(Connection) ->
        {ok, _Columns, [{Value}]} = epgsql:squery(Connection, Sql),
        binary_to_integer(Value)
    end);
count(#{kind := mysql} = Spec, Config, Sql) ->
    with_mysql_connection(Spec, proplists:get_value(database, Config), fun(Connection) ->
        {ok, _Columns, [[N]]} = mysql:query(Connection, Sql),
        N
    end).

table_exists(Spec, Config, Table) ->
    count(Spec, Config, table_exists_sql(Spec, Table)).

table_exists_sql(#{kind := pg}, Table) ->
    "SELECT count(*) FROM information_schema.tables"
        " WHERE table_schema = 'public' AND table_name = '" ++ Table ++ "'";
table_exists_sql(#{kind := mysql}, Table) ->
    "SELECT count(*) FROM information_schema.tables"
        " WHERE table_schema = DATABASE() AND table_name = '" ++ Table ++ "'";
table_exists_sql(#{kind := sqlite}, Table) ->
    "SELECT count(*) FROM sqlite_master WHERE type = 'table' AND name = '" ++ Table ++ "'".

failed_history_sql(#{kind := pg}) ->
    "SELECT count(*) FROM migrations WHERE success = FALSE";
failed_history_sql(_Spec) ->
    "SELECT count(*) FROM migrations WHERE success = 0".

successful_history_sql(#{kind := pg}) ->
    "SELECT count(*) FROM migrations WHERE success = TRUE";
successful_history_sql(_Spec) ->
    "SELECT count(*) FROM migrations WHERE success = 1".

with_pg_connection(#{host := Host, port := Port, user := User, password := Password}, Database, Fun) ->
    {ok, Connection} = epgsql:connect(Host, User, Password, [{port, Port}, {database, Database}]),
    try
        Fun(Connection)
    after
        unlink(Connection),
        catch epgsql:close(Connection),
        drain_exit(Connection)
    end.

with_mysql_connection(#{host := Host, port := Port, user := User, password := Password}, Database, Fun) ->
    Options = [
        {host, Host},
        {port, Port},
        {user, User},
        {password, Password},
        {database, Database}
    ],
    {ok, Connection} = mysql:start_link(Options),
    try
        Fun(Connection)
    after
        unlink(Connection),
        catch mysql:stop(Connection),
        drain_exit(Connection)
    end.

exec_pg(Connection, Sql) ->
    case epgsql:squery(Connection, Sql) of
        {error, Reason} ->
            erlang:error({pg_admin_query_failed, Sql, Reason});
        _Result ->
            ok
    end.

%% Small helpers.

spec_label(#{kind := Kind}) ->
    atom_to_list(Kind).

unique_name(Prefix) ->
    Prefix ++ "_" ++ integer_to_list(erlang:unique_integer([positive])).

tmp_dir() ->
    case os:getenv("TMPDIR") of
        false ->
            "/tmp";
        Dir ->
            Dir
    end.

temp_migrations_dir() ->
    filename:join(tmp_dir(), unique_name("parrot_it_migrations")).

write_migration_files(Dir, Files) ->
    lists:foreach(
        fun({Name, Content}) ->
            ok = file:write_file(filename:join(Dir, Name), Content)
        end,
        Files
    ).

delete_dir(Dir) ->
    case file:list_dir(Dir) of
        {ok, Names} ->
            lists:foreach(fun(Name) -> file:delete(filename:join(Dir, Name)) end, Names),
            file:del_dir(Dir),
            ok;
        {error, _Reason} ->
            ok
    end.

env_integer(Name, Default) ->
    case os:getenv(Name) of
        false ->
            Default;
        Value ->
            list_to_integer(Value)
    end.

env_string(Name, Default) ->
    case os:getenv(Name) of
        false ->
            Default;
        Value ->
            Value
    end.

drain_exit(Pid) ->
    receive
        {'EXIT', Pid, _Reason} ->
            ok
    after 0 ->
        ok
    end.

drain_exit_messages() ->
    receive
        {'EXIT', _Pid, _Reason} ->
            drain_exit_messages()
    after 0 ->
        ok
    end.
