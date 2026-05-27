-module(parrot_driver).
-export([get_connection/1]).

get_connection(Config) ->
    Host = proplists:get_value(host, Config, "localhost"),
    Port = proplists:get_value(port, Config, 5432),
    User = proplists:get_value(user, Config, "postgres"),
    Password = proplists:get_value(password, Config, "postgres"),
    Database = proplists:get_value(database, Config, "postgres"),
    Opts = [{port, Port}, {database, Database}],
    epgsql:connect(Host, User, Password, Opts).
