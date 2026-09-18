-module(parrot_validation).

-export([
    validate_config/1,
    validate_files/1,
    validate_history/3,
    checksum/1,
    pending_upgrades/2,
    no_pending_reason/2,
    describe_reason/1,
    missing_downgrades/1,
    parse_upgrade_file/1,
    parse_migration_file/1,
    upgrade_to_downgrade_filename/1,
    version_key_first_three/1,
    upgrade_files_first_three_keys/1
]).

-define(UPGRADE_FILE_RE, "^([0-9]{3,})_[A-Za-z0-9_-]+_upgrade\\.sql$").
-define(MIGRATION_FILE_RE, "^([0-9]{3,})_[A-Za-z0-9_-]+_(upgrade|downgrade)\\.sql$").
-define(VERSION_PREFIX_RE, "^([0-9]{3,})_").

validate_config(Config) ->
    StringFields = [host, user, password, database],
    case first_invalid_string_field(StringFields, Config) of
        undefined ->
            validate_port_field(Config);
        {missing, Field} ->
            {error, {missing_config_field, Field}};
        {empty, Field} ->
            {error, {invalid_config_field, Field, non_empty_string_or_binary}}
    end.

first_invalid_string_field([], _Config) ->
    undefined;
first_invalid_string_field([Field | Rest], Config) ->
    case proplists:get_value(Field, Config) of
        undefined ->
            {missing, Field};
        Value ->
            case is_nonempty_stringy(Value) of
                true ->
                    first_invalid_string_field(Rest, Config);
                false ->
                    {empty, Field}
            end
    end.

validate_port_field(Config) ->
    case proplists:get_value(port, Config) of
        undefined ->
            {error, {missing_config_field, port}};
        Port when is_integer(Port) ->
            ok;
        _ ->
            {error, {invalid_config_field, port, integer}}
    end.

is_nonempty_stringy(Value) when is_binary(Value) ->
    byte_size(Value) > 0;
is_nonempty_stringy(Value) when is_list(Value) ->
    Value =/= [];
is_nonempty_stringy(_Value) ->
    false.

validate_files(Files) ->
    SqlFiles = lists:filter(fun is_sql_file/1, Files),
    case collect_filename_errors(SqlFiles) of
        [FirstError | _] ->
            {error, FirstError};
        [] ->
            Warnings = invalid_suffix_warnings(SqlFiles) ++ missing_downgrade_warnings(SqlFiles),
            case duplicate_upgrade_keys(SqlFiles) of
                ok ->
                    {ok, Warnings};
                {error, Reason} ->
                    {error, Reason}
            end
    end.

is_sql_file(Name) ->
    lists:suffix(".sql", Name).

collect_filename_errors(SqlFiles) ->
    lists:filtermap(
        fun(File) ->
            case has_version_prefix(File) of
                true ->
                    false;
                false ->
                    {true, {invalid_migration_filename, File}}
            end
        end,
        SqlFiles
    ).

has_version_prefix(File) ->
    case re:run(File, ?VERSION_PREFIX_RE) of
        {match, _} ->
            true;
        nomatch ->
            false
    end.

invalid_suffix_warnings(SqlFiles) ->
    [{invalid_migration_suffix, File}
     || File <- SqlFiles,
        has_version_prefix(File),
        parse_migration_file(File) =:= ignore].

missing_downgrade_warnings(SqlFiles) ->
    [{missing_downgrade, File, Expected}
     || File <- SqlFiles,
        {ok, _} <- [parse_upgrade_file(File)],
        Expected <- [upgrade_to_downgrade_filename(File)],
        not lists:member(Expected, SqlFiles)].

duplicate_upgrade_keys(SqlFiles) ->
    Pairs = [{version_key_first_three(Version), File}
             || File <- SqlFiles,
                {ok, {Version, _File}} <- [parse_upgrade_file(File)]],
    Grouped = lists:foldl(
        fun({Key, File}, Acc) ->
            L = maps:get(Key, Acc, []),
            maps:put(Key, [File | L], Acc)
        end,
        #{},
        Pairs
    ),
    case maps:fold(
        fun(Key, Fs, Dupes) ->
            case lists:usort(Fs) of
                [_] ->
                    Dupes;
                Multi ->
                    [{Key, Multi} | Dupes]
            end
        end,
        [],
        Grouped
    ) of
        [] ->
            ok;
        [{Key, Files} | _] ->
            {error, {duplicate_migration_version, Key, Files}}
    end.

version_key_first_three(Version) when is_list(Version) ->
    lists:sublist(Version, 3).

upgrade_files_first_three_keys(SqlFiles) ->
    lists:filtermap(
        fun(File) ->
            case parse_upgrade_file(File) of
                {ok, {Version, _UpgradeFile}} ->
                    {true, {version_key_first_three(Version), File}};
                _ ->
                    false
            end
        end,
        SqlFiles
    ).

validate_history(Files, History, Path) ->
    FileSet = ordsets:from_list(Files),
    validate_history_rows(FileSet, History, Path).

validate_history_rows(_FileSet, [], _Path) ->
    ok;
validate_history_rows(FileSet, [{_Version, File, ExpectedChecksum} | Rest], Path) ->
    case ordsets:is_element(File, FileSet) of
        false ->
            validate_history_rows(FileSet, Rest, Path);
        true ->
            case file:read_file(filename:join(Path, File)) of
                {ok, Migration} ->
                    case checksum(Migration) of
                        ExpectedChecksum ->
                            validate_history_rows(FileSet, Rest, Path);
                        CurrentChecksum ->
                            {error, {checksum_mismatch, File, ExpectedChecksum, CurrentChecksum}}
                    end;
                {error, _Reason} ->
                    validate_history_rows(FileSet, Rest, Path)
            end
    end.

pending_upgrades(Files, CurrentVersion) ->
    Upgrades = [Migration || File <- Files,
                             {ok, Migration} <- [parse_upgrade_file(File)],
                             migration_version(Migration) > CurrentVersion],
    lists:sort(Upgrades).

no_pending_reason(Files, CurrentVersion) ->
    case pending_upgrades(Files, CurrentVersion) of
        [_ | _] ->
            undefined;
        [] ->
            case has_upgrade_files(Files) of
                true ->
                    already_up_to_date;
                false ->
                    case unrecognized_migration_files(Files) of
                        [] ->
                            no_sql_files;
                        Unrecognized ->
                            {unrecognized_migration_files, Unrecognized}
                    end
            end
    end.

describe_reason(no_sql_files) ->
    "no upgrade migrations were applied: migrations directory contains no .sql files";
describe_reason(already_up_to_date) ->
    "no upgrade migrations were applied: database schema is already up to date";
describe_reason({unrecognized_migration_files, Unrecognized}) ->
    Details = [
        io_lib:format("~s (~s)", [File, migration_file_issue_label(Issue)])
     || {File, Issue} <- Unrecognized
    ],
    "no upgrade migrations were applied: found .sql files that do not match "
        "NNN_name_upgrade.sql: "
        ++ lists:flatten(string:join(Details, "; "));
describe_reason({no_migrations_applied, Reason, Path}) ->
    lists:flatten([
        describe_reason(Reason),
        " (migrations_dir: ",
        Path,
        ")"
    ]);
describe_reason(Reason) ->
    io_lib:format("~p", [Reason]).

migration_version({Version, _File}) ->
    Version.

has_upgrade_files(Files) ->
    lists:any(fun(File) -> parse_upgrade_file(File) =/= ignore end, Files).

unrecognized_migration_files(Files) ->
    lists:sort([
        {File, Issue}
     || File <- Files,
        is_sql_file(File),
        Issue <- [migration_file_issue(File)],
        Issue =/= undefined
    ]).

migration_file_issue(File) ->
    case parse_upgrade_file(File) of
        {ok, _} ->
            undefined;
        ignore ->
            case has_version_prefix(File) of
                false ->
                    missing_version_prefix;
                true ->
                    case parse_migration_file(File) of
                        {ok, _Version, _Name, "downgrade"} ->
                            downgrade_only;
                        _ ->
                            invalid_upgrade_suffix
                    end
            end
    end.

migration_file_issue_label(missing_version_prefix) ->
    "filename must start with a 3+ digit version prefix, for example 001_name_upgrade.sql";
migration_file_issue_label(invalid_upgrade_suffix) ->
    "filename must end with _upgrade.sql";
migration_file_issue_label(downgrade_only) ->
    "downgrade file without a matching *_upgrade.sql migration".

parse_upgrade_file(File) ->
    case re:run(File, ?UPGRADE_FILE_RE, [{capture, [1], list}]) of
        {match, [Version]} ->
            {ok, {Version, File}};
        nomatch ->
            ignore
    end.

parse_migration_file(File) ->
    case re:run(File, ?MIGRATION_FILE_RE, [{capture, [1, 2, 3], list}]) of
        {match, [Version, Name, Direction]} ->
            {ok, as_string(Version), as_string(Name), as_string(Direction)};
        nomatch ->
            ignore
    end.

as_string(Value) when is_binary(Value) ->
    binary_to_list(Value);
as_string(Value) when is_list(Value) ->
    Value.

missing_downgrades(Files) ->
    [{File, Expected}
     || File <- Files,
        {ok, _} <- [parse_upgrade_file(File)],
        Expected <- [upgrade_to_downgrade_filename(File)],
        not lists:member(Expected, Files)].

upgrade_to_downgrade_filename(UpgradeFile) ->
    UpgradeSuffix = "_upgrade.sql",
    PrefixLength = length(UpgradeFile) - length(UpgradeSuffix),
    lists:sublist(UpgradeFile, PrefixLength) ++ "_downgrade.sql".

checksum(Migration) ->
    lists:flatten([hex_byte(Byte) || Byte <- binary_to_list(crypto:hash(sha256, Migration))]).

hex_byte(Byte) when Byte < 16 ->
    [$0 | integer_to_list(Byte, 16)];
hex_byte(Byte) ->
    integer_to_list(Byte, 16).
