-- Prints the owner, privileges and security settings of every object in
-- schema public, one "KEY<TAB>ATTRIBUTES" line each, sorted, so that two
-- databases can be compared with diff. scripts/byoh/migrate-from-dev.sh
-- copy-db runs it as postgres on the migrated copy and on a reference
-- database migrated from scratch at the same release; every object both
-- have must print the same line.
--
-- Keys: schema|public, rel|<relkind>|<name>, col|<table>.<column>,
-- fn|<regprocedure>, type|<name>. ACL items are sorted, so the order in
-- which grants were made does not matter.

\set ON_ERROR_STOP 1
\pset format unaligned
\pset tuples_only on
\pset fieldsep '\t'

WITH acl(oid, kind, items) AS (
  SELECT c.oid, 'rel', c.relacl FROM pg_class c
  UNION ALL SELECT p.oid, 'fn', p.proacl FROM pg_proc p
  UNION ALL SELECT n.oid, 'schema', n.nspacl FROM pg_namespace n
  UNION ALL SELECT t.oid, 'type', t.typacl FROM pg_type t
),
norm AS (
  SELECT oid, kind, coalesce((SELECT string_agg(x::text, ',' ORDER BY x::text) FROM unnest(items) x), '') AS acl
  FROM acl
)
SELECT 'schema|public', format('owner=%s acl=%s', pg_get_userbyid(n.nspowner), a.acl)
FROM pg_namespace n JOIN norm a ON a.oid = n.oid AND a.kind = 'schema'
WHERE n.nspname = 'public'
UNION ALL
SELECT format('rel|%s|%s', c.relkind, c.relname), format('owner=%s acl=%s', pg_get_userbyid(c.relowner), a.acl)
FROM pg_class c JOIN norm a ON a.oid = c.oid AND a.kind = 'rel'
WHERE c.relnamespace = 'public'::regnamespace AND c.relkind IN ('r', 'p', 'v', 'm', 'S', 'f')
UNION ALL
SELECT format('col|%s.%s', c.relname, att.attname),
  format('acl=%s', (SELECT string_agg(x::text, ',' ORDER BY x::text) FROM unnest(att.attacl) x))
FROM pg_attribute att JOIN pg_class c ON c.oid = att.attrelid
WHERE c.relnamespace = 'public'::regnamespace AND att.attacl IS NOT NULL AND NOT att.attisdropped
UNION ALL
SELECT format('fn|%s', p.oid::regprocedure),
  format('owner=%s acl=%s secdef=%s config=%s public_exec=%s', pg_get_userbyid(p.proowner), a.acl,
    p.prosecdef, coalesce(array_to_string(p.proconfig, ','), ''), has_function_privilege('public', p.oid, 'EXECUTE'))
FROM pg_proc p JOIN norm a ON a.oid = p.oid AND a.kind = 'fn'
WHERE p.pronamespace = 'public'::regnamespace
UNION ALL
SELECT format('type|%s', t.typname), format('owner=%s acl=%s', pg_get_userbyid(t.typowner), a.acl)
FROM pg_type t JOIN norm a ON a.oid = t.oid AND a.kind = 'type'
WHERE t.typnamespace = 'public'::regnamespace AND t.typtype IN ('e', 'r', 'd')
ORDER BY 1;
