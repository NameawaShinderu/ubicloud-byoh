-- Retires the development bootstrap's database and superuser once the
-- packaged control plane has run on its own long enough
-- (scripts/byoh/migrate-from-dev.sh retire). Runs as postgres, connected
-- to database postgres, with -v dev_db=clover_test
-- -v retired_db=clover_test_retired_<date> -v dev_role=clover. The
-- database is renamed, never dropped; the roles keep their objects but
-- can no longer log in, and the superuser stops being one.

\set ON_ERROR_STOP 1

ALTER DATABASE :"dev_db" ALLOW_CONNECTIONS false;
ALTER DATABASE :"dev_db" RENAME TO :"retired_db";
ALTER ROLE :"dev_role" NOLOGIN NOSUPERUSER;

SELECT format('ALTER ROLE %I NOLOGIN', :'dev_role' || '_password')
WHERE EXISTS (SELECT 1 FROM pg_roles WHERE rolname = :'dev_role' || '_password') \gexec
