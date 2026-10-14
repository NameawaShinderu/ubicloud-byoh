-- Hands the objects of a database copied from the development bootstrap
-- (pg_restore --no-owner --no-acl, so every object belongs to the role
-- that restored it) to the packaged control plane's roles, and replays
-- the grants of the password-hash migrations, which --no-acl dropped.
-- scripts/byoh/migrate-from-dev.sh copy-db runs it as postgres, once,
-- on the copy before its pending migrations run:
--
--   psql -v app_role=ubicloud -v ph_role=ubicloud_password \
--     -v src_ph_tables=a,b -v src_ph_funcs='f(uuid)|g(uuid,text)' -f THIS
--
-- src_ph_tables and src_ph_funcs name what the source database's
-- <role>_password owned (relations by name, routines by regprocedure).
-- Those go to ph_role; every other object in schema public goes to
-- app_role, the deleted_record_* partitions respirate made included.
-- Objects of extensions stay with postgres, which created them. There is
-- no REASSIGN OWNED: the restoring role also owns nothing else.
--
-- The statements of the grant section are the ones migrate/ph/*.rb and
-- migrate/20230315_rodauth.rb and 20250716_admin_accounts.rb run with
-- current_user = app_role. A superuser's GRANT and REVOKE are recorded
-- as the object owner's, as when ph_role ran them itself, so the result
-- compares equal to a fresh migrate (migrate-compare.sql).

\set ON_ERROR_STOP 1

BEGIN;

CREATE TEMP TABLE byoh_map_args ON COMMIT DROP AS
SELECT :'app_role'::text AS app, :'ph_role'::text AS ph,
  coalesce(string_to_array(nullif(:'src_ph_tables', ''), ','), '{}') AS ph_rels,
  coalesce(string_to_array(nullif(:'src_ph_funcs', ''), '|'), '{}') AS ph_funcs;

DO $$
DECLARE
  a record;
  r record;
  target text;
  missing text;
BEGIN
  SELECT * INTO a FROM byoh_map_args;

  -- Every object the source's ph role owned must be in the copy.
  SELECT string_agg(n, ', ') INTO missing FROM unnest(a.ph_rels) n
  WHERE to_regclass('public.' || quote_ident(n)) IS NULL;
  IF missing IS NOT NULL THEN
    RAISE EXCEPTION 'the copy lacks relation(s) the source''s password role owned: %', missing;
  END IF;
  SELECT string_agg(n, ', ') INTO missing FROM unnest(a.ph_funcs) n
  WHERE to_regprocedure(n) IS NULL;
  IF missing IS NOT NULL THEN
    RAISE EXCEPTION 'the copy lacks routine(s) the source''s password role owned: %', missing;
  END IF;

  EXECUTE format('ALTER SCHEMA public OWNER TO %I', a.app);

  -- Relations. Indexes and TOAST tables follow their table, and so do
  -- sequences linked to a column (serial or identity), which refuse
  -- an ALTER of their own.
  FOR r IN
    SELECT c.relname, c.relkind FROM pg_class c
    WHERE c.relnamespace = 'public'::regnamespace
      AND c.relkind IN ('r', 'p', 'v', 'm', 'S', 'f')
      AND NOT EXISTS (SELECT 1 FROM pg_depend d
        WHERE d.classid = 'pg_class'::regclass AND d.objid = c.oid AND d.deptype = 'e')
      AND NOT (c.relkind = 'S' AND EXISTS (SELECT 1 FROM pg_depend d
        WHERE d.classid = 'pg_class'::regclass AND d.objid = c.oid
          AND d.refclassid = 'pg_class'::regclass AND d.deptype IN ('a', 'i')))
    ORDER BY c.relkind = 'S', c.relname
  LOOP
    target := CASE WHEN r.relname = ANY(a.ph_rels) THEN a.ph ELSE a.app END;
    EXECUTE format('ALTER %s public.%I OWNER TO %I',
      CASE r.relkind WHEN 'S' THEN 'SEQUENCE' WHEN 'v' THEN 'VIEW'
        WHEN 'm' THEN 'MATERIALIZED VIEW' WHEN 'f' THEN 'FOREIGN TABLE' ELSE 'TABLE' END,
      r.relname, target);
  END LOOP;

  -- Types of their own: enums, ranges, domains and standalone composite
  -- types. Row types and array types follow their table or element type.
  FOR r IN
    SELECT t.typname, t.typtype FROM pg_type t
    WHERE t.typnamespace = 'public'::regnamespace
      AND t.typtype IN ('e', 'r', 'd', 'c')
      AND (t.typtype <> 'c' OR (SELECT c.relkind FROM pg_class c WHERE c.oid = t.typrelid) = 'c')
      AND NOT EXISTS (SELECT 1 FROM pg_depend d
        WHERE d.classid = 'pg_type'::regclass AND d.objid = t.oid AND d.deptype = 'e')
  LOOP
    EXECUTE format('ALTER %s public.%I OWNER TO %I',
      CASE r.typtype WHEN 'd' THEN 'DOMAIN' ELSE 'TYPE' END, r.typname, a.app);
  END LOOP;

  -- Routines. The password-hash functions are SECURITY DEFINER, so
  -- their owner decides what they can read.
  FOR r IN
    SELECT p.oid::regprocedure::text AS sig, p.prokind FROM pg_proc p
    WHERE p.pronamespace = 'public'::regnamespace
      AND NOT EXISTS (SELECT 1 FROM pg_depend d
        WHERE d.classid = 'pg_proc'::regclass AND d.objid = p.oid AND d.deptype = 'e')
  LOOP
    target := CASE WHEN r.sig = ANY(a.ph_funcs) THEN a.ph ELSE a.app END;
    EXECUTE format('ALTER %s %s OWNER TO %I',
      CASE r.prokind WHEN 'p' THEN 'PROCEDURE' WHEN 'a' THEN 'AGGREGATE' ELSE 'FUNCTION' END,
      r.sig, target);
  END LOOP;

  -- The grants of the migrations, for the objects the copy has (a
  -- password-hash migration still pending makes its own).
  IF to_regclass('public.accounts') IS NOT NULL THEN
    EXECUTE format('GRANT REFERENCES ON accounts TO %I', a.ph);
  END IF;
  IF to_regclass('public.admin_account') IS NOT NULL THEN
    EXECUTE format('GRANT REFERENCES ON admin_account TO %I', a.ph);
  END IF;
  IF to_regclass('public.account_password_hashes') IS NOT NULL THEN
    EXECUTE 'REVOKE ALL ON account_password_hashes FROM public';
    EXECUTE 'REVOKE ALL ON FUNCTION rodauth_get_salt(uuid) FROM public';
    EXECUTE 'REVOKE ALL ON FUNCTION rodauth_valid_password_hash(uuid, text) FROM public';
    EXECUTE format('GRANT INSERT, UPDATE, DELETE ON account_password_hashes TO %I', a.app);
    EXECUTE format('GRANT SELECT(id) ON account_password_hashes TO %I', a.app);
    EXECUTE format('GRANT EXECUTE ON FUNCTION rodauth_get_salt(uuid) TO %I', a.app);
    EXECUTE format('GRANT EXECUTE ON FUNCTION rodauth_valid_password_hash(uuid, text) TO %I', a.app);
  END IF;
  IF to_regclass('public.account_previous_password_hashes') IS NOT NULL THEN
    EXECUTE 'REVOKE ALL ON account_previous_password_hashes FROM public';
    EXECUTE 'REVOKE ALL ON FUNCTION rodauth_get_previous_salt(uuid) FROM public';
    EXECUTE 'REVOKE ALL ON FUNCTION rodauth_previous_password_hash_match(uuid, text) FROM public';
    EXECUTE format('GRANT INSERT, UPDATE, DELETE ON account_previous_password_hashes TO %I', a.app);
    EXECUTE format('GRANT SELECT(id, account_id) ON account_previous_password_hashes TO %I', a.app);
    EXECUTE format('GRANT EXECUTE ON FUNCTION rodauth_get_previous_salt(uuid) TO %I', a.app);
    EXECUTE format('GRANT EXECUTE ON FUNCTION rodauth_previous_password_hash_match(uuid, text) TO %I', a.app);
  END IF;
  IF to_regclass('public.admin_password_hash') IS NOT NULL THEN
    EXECUTE 'REVOKE ALL ON admin_password_hash FROM public';
    EXECUTE 'REVOKE ALL ON FUNCTION rodauth_admin_get_salt(uuid) FROM public';
    EXECUTE 'REVOKE ALL ON FUNCTION rodauth_admin_valid_password_hash(uuid, text) FROM public';
    EXECUTE format('GRANT INSERT, UPDATE, DELETE ON admin_password_hash TO %I', a.app);
    EXECUTE format('GRANT SELECT(id) ON admin_password_hash TO %I', a.app);
    EXECUTE format('GRANT EXECUTE ON FUNCTION rodauth_admin_get_salt(uuid) TO %I', a.app);
    EXECUTE format('GRANT EXECUTE ON FUNCTION rodauth_admin_valid_password_hash(uuid, text) TO %I', a.app);
  END IF;
END
$$;

COMMIT;
