-module(parrot_fake_legacy_driver).

%% A driver written against the original behaviour: it implements only
%% the required callbacks (no lock/2, unlock/2) and delegates everything
%% to parrot_fake_driver, so the same ETS helpers can inspect a run.

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

validate_config(Config) ->
    parrot_fake_driver:validate_config(Config).

connect(Config) ->
    parrot_fake_driver:connect(Config).

close(Tab) ->
    parrot_fake_driver:close(Tab).

ensure_schema(Tab) ->
    parrot_fake_driver:ensure_schema(Tab).

lock(Tab) ->
    parrot_fake_driver:lock(Tab).

unlock(Tab) ->
    parrot_fake_driver:unlock(Tab).

begin_tx(Tab) ->
    parrot_fake_driver:begin_tx(Tab).

commit(Tab) ->
    parrot_fake_driver:commit(Tab).

rollback(Tab) ->
    parrot_fake_driver:rollback(Tab).

run_migration(Tab, Migration) ->
    parrot_fake_driver:run_migration(Tab, Migration).

record_migration(Tab, Version, Name, Checksum, Success) ->
    parrot_fake_driver:record_migration(Tab, Version, Name, Checksum, Success).

get_success_history(Tab) ->
    parrot_fake_driver:get_success_history(Tab).
