PROJECT = parrot
PROJECT_DESCRIPTION = Database migrations library for Erlang applications
PROJECT_VERSION = 0.1.0

DEPS = epgsql mysql esqlite
dep_epgsql = git https://github.com/epgsql/epgsql.git 4.8.0
dep_mysql = git https://github.com/mysql-otp/mysql-otp.git 1.9.0
dep_esqlite = hex 0.8.9

# crypto is used for migration checksums; include it in the Dialyzer PLT.
PLT_APPS = crypto

include erlang.mk

.PHONY: tests-integration

tests-integration:
	./scripts/integration-tests.sh
