-module(parrot_fake_driver).

%% In-memory fake driver for exercising the migration orchestration in
%% parrot_migration / parrot without a real database.
%%
%% State lives in a public ETS table created by the test via new/0,1 and
%% passed to the driver through the {fake_state, Tab} config entry, so it
%% survives parrot_driver:close/1 and can be inspected after a run.
%%
%% The fake records every driver call (in order) under `calls' and every
%% record_migration row (successful or not) under `history'. Operations
%% listed in the fail map given to new/1 return {error, Reason}.

-behaviour(parrot_driver).

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

%% Test helpers.
-export([new/0, new/1, delete/1, calls/1, history/1]).

new() ->
    new(#{}).

new(FailMap) when is_map(FailMap) ->
    Tab = ets:new(parrot_fake_driver, [set, public]),
    ets:insert(Tab, {calls, []}),
    ets:insert(Tab, {history, []}),
    ets:insert(Tab, {fail, FailMap}),
    Tab.

delete(Tab) ->
    ets:delete(Tab),
    ok.

%% Driver calls in the order they happened.
calls(Tab) ->
    lists:reverse(lookup(Tab, calls)).

%% All recorded history rows (including success = false) in insertion order.
history(Tab) ->
    lists:reverse(lookup(Tab, history)).

%% parrot_driver callbacks.

validate_config(_Config) ->
    ok.

connect(Config) ->
    case proplists:get_value(fake_state, Config) of
        undefined ->
            {error, missing_fake_state};
        Tab ->
            {ok, Tab}
    end.

close(_Tab) ->
    ok.

ensure_schema(Tab) ->
    op(Tab, ensure_schema).

lock(Tab) ->
    op(Tab, lock).

unlock(Tab) ->
    record_call(Tab, unlock),
    ok.

begin_tx(Tab) ->
    op(Tab, begin_tx).

commit(Tab) ->
    op(Tab, commit).

rollback(Tab) ->
    op(Tab, rollback).

run_migration(Tab, _Migration) ->
    case op(Tab, run_migration) of
        ok ->
            {ok, fake_executed};
        {error, Reason} ->
            {error, Reason}
    end.

record_migration(Tab, Version, Name, Checksum, Success) ->
    case op(Tab, record_migration) of
        ok ->
            append(Tab, history, {Version, Name, Checksum, Success}),
            ok;
        {error, Reason} ->
            {error, Reason}
    end.

get_success_history(Tab) ->
    case op(Tab, get_success_history) of
        ok ->
            {ok, [{Version, Name, Checksum}
                  || {Version, Name, Checksum, true} <- history(Tab)]};
        {error, Reason} ->
            {error, Reason}
    end.

%% Internal.

op(Tab, Op) ->
    record_call(Tab, Op),
    case maps:find(Op, lookup(Tab, fail)) of
        {ok, Reason} ->
            {error, Reason};
        error ->
            ok
    end.

record_call(Tab, Op) ->
    append(Tab, calls, Op).

append(Tab, Key, Value) ->
    ets:insert(Tab, {Key, [Value | lookup(Tab, Key)]}).

lookup(Tab, Key) ->
    [{Key, Value}] = ets:lookup(Tab, Key),
    Value.
