PROJECT = parrot
PROJECT_DESCRIPTION = PostgreSQL migrations library for Erlang applications
PROJECT_VERSION = 0.1.0

BUILD_DEPS = epgsql
dep_epgsql = git https://github.com/epgsql/epgsql.git 4.8.0

include erlang.mk
